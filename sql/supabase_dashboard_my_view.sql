-- Dashboard "My View" (super users only) - per "build a new dashboard above sales which is My View.
-- I want to see how the business is doing base on how the real accounting see it. like see total
-- sales, total expense, total business owners spent, bill payables etc."
--
-- One RPC, admin_get_my_view(from, to), returns everything the tab draws as one jsonb:
--
--   pnl       Income statement for the period, ACCRUAL style (how an accountant reads it):
--               Revenue      = Online + Walk-In sales (OnlineOrders.MoneyToCollect by "Date", not
--                              cancelled) - exactly the Sales tab's "Total Sales" rules.
--               COGS         = what the items SOLD cost, NOT what was purchased. Per line:
--                              qty x Items."Cost" (portal-owned last cost; by the line's item, else
--                              its variant's item), falling back to the line's own UnitCost.
--                              cogs_coverage = share of sales value that had a cost - lines with
--                              no cost (custom builds, SETs, uncosted items) count as zero, so the
--                              page warns when coverage is low.
--               OpEx         = POS expenses + Expense Journal (incl. Bills & Dues and owner-paid
--                              expenses - an expense is the business's whoever paid it), by category
--                              + Salaries & Wages = payroll GROSS (BasePay + Additions) by PayDate.
--               Net Profit   = Revenue - COGS - OpEx.
--             Purchases are deliberately NOT an expense here: buying stock turns cash into
--             inventory; it hits profit only as COGS when sold. Shown separately under cash out.
--   prev      Same P&L for the equal-length period right before (for the "vs previous" deltas).
--   trend     P&L per calendar month, the 6 months ending at p_to.
--   position  Snapshot as of today: inventory at cost (Item Ledger qty x Items.Cost), receivables
--             (unpaid online-order balances), vendor payables (bills - payments), Bills & Dues
--             overdue / due in 30 days, owed to owner (Owner Loan - repayments), customer deposits
--             on advance orders not yet turned into an order, all-time capital in / drawings.
--   owner     Owner Funds activity in the period (capital in, loans, paid directly, drawings,
--             repayments).
--   cash_out  Money that left in the period by kind: purchases received, vendor payments, payroll
--             net pay, Bills & Dues paid (business vs owner).
--   upcoming  Bills & Dues + open vendor bills that are overdue or due in the next 30 days.
--
-- Read-only. Run AFTER supabase_business_bills.sql (uses _business_bill_due_dates) and
-- supabase_owner_funds.sql. Safe to re-run.

create index if not exists "IX_OnlineOrders_Date" on public."OnlineOrders" ("Date");

-- ---------------------------------------------------------------------------
-- P&L for one date range. No auth check - only called by admin_get_my_view, never granted.
create or replace function public._my_view_pnl(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_sales record;
  v_cogs record;
  v_exp jsonb;
  v_exp_total numeric;
  v_pay record;
  v_revenue numeric;
  v_opex numeric;
begin
  select
    coalesce(sum(o."MoneyToCollect") filter (where o."ReceivedAtShop" is not true), 0) as online_sales,
    count(*) filter (where o."ReceivedAtShop" is not true)::int as online_count,
    coalesce(sum(o."MoneyToCollect") filter (where o."ReceivedAtShop" is true), 0) as walkin_sales,
    count(*) filter (where o."ReceivedAtShop" is true)::int as walkin_count
  into v_sales
  from public."OnlineOrders" o
  where o."Date" >= p_from and o."Date" <= p_to
    and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled');

  with lines as (
    select coalesce(l."NetAmount", coalesce(l."Price", 0) * coalesce(l."Quantity", 0)) as line_value,
           coalesce(l."Quantity", 0) as qty,
           coalesce(nullif(i."Cost", 0), nullif(vi."Cost", 0), nullif(l."UnitCost", 0)) as unit_cost
    from public."OnlineOrders" o
    join public."OnlineOrderLines" l on l."OrderID" = o."OrderID"
    left join public."Items" i on i."Code" = l."ItemCode"
    left join public."Variants" v on v."VariationId" = l."VariationId"
    left join public."Items" vi on vi."Code" = v."ItemCode"
    where o."Date" >= p_from and o."Date" <= p_to
      and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
  )
  select coalesce(sum(qty * unit_cost), 0) as cogs,
         coalesce(sum(line_value) filter (where unit_cost is not null), 0) as costed_value,
         coalesce(sum(line_value), 0) as line_value,
         count(*) filter (where unit_cost is null and qty <> 0)::int as uncosted_lines
  into v_cogs
  from lines;

  with x as (
    select coalesce(nullif(trim(e."ExpenseCategory"), ''), '(No category)') as cat, coalesce(e."NetAmount", 0) as amt
    from public."ExpenseEntryHeader" e
    where e."Date" >= p_from and e."Date" <= p_to
    union all
    select coalesce(nullif(trim(j."ExpenseCategory"), ''), '(No category)'), coalesce(j."Amount", 0)
    from public."ExpenseJournalEntries" j
    where j."EntryDate" >= p_from and j."EntryDate" <= p_to
  ),
  g as (
    select x.cat::text as code, coalesce(min(c."Description"), x.cat)::text as category,
           sum(x.amt) as amount, count(*)::int as entries
    from x
    left join public."ExpenseJournalCategories" c on c."Code" = x.cat
    group by x.cat
  )
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'category', category, 'amount', amount, 'entries', entries)
                            order by amount desc), '[]'::jsonb),
         coalesce(sum(amount), 0)
  into v_exp, v_exp_total
  from g;

  select coalesce(sum(p."Amount") filter (where p."EntryType" in ('BasePay', 'Addition')), 0) as gross,
         coalesce(sum(p."Amount") filter (where p."EntryType" = 'NetPay'), 0) as net,
         count(distinct p."Username")::int as employees
  into v_pay
  from public."PayrollLedgerEntries" p
  where p."PayDate" >= p_from and p."PayDate" <= p_to;

  v_revenue := v_sales.online_sales + v_sales.walkin_sales;
  v_opex := v_exp_total + v_pay.gross;

  return jsonb_build_object(
    'online_sales', v_sales.online_sales, 'online_count', v_sales.online_count,
    'walkin_sales', v_sales.walkin_sales, 'walkin_count', v_sales.walkin_count,
    'revenue', v_revenue,
    'cogs', round(v_cogs.cogs, 2),
    'cogs_coverage', case when v_cogs.line_value > 0 then round(v_cogs.costed_value / v_cogs.line_value, 4) else null end,
    'uncosted_lines', v_cogs.uncosted_lines,
    'gross_profit', round(v_revenue - v_cogs.cogs, 2),
    'expense_categories', v_exp,
    'expense_total', v_exp_total,
    'payroll_gross', v_pay.gross,
    'payroll_net', v_pay.net,
    'payroll_employees', v_pay.employees,
    'opex_total', v_opex,
    'net_profit', round(v_revenue - v_cogs.cogs - v_opex, 2)
  );
end;
$$;

revoke execute on function public._my_view_pnl(date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
drop function if exists public.admin_get_my_view(text, text, date, date);

create or replace function public.admin_get_my_view(
  p_admin_username text,
  p_admin_password text,
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_days int;
  v_trend jsonb;
  v_position jsonb;
  v_owner jsonb;
  v_cash jsonb;
  v_upcoming jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Pick a valid date range.';
  end if;
  v_days := p_to - p_from + 1;

  -- 6 calendar months ending with p_to's month (the current month runs to date).
  select jsonb_agg(jsonb_build_object('month', m.month_start) || public._my_view_pnl(m.month_start, least(m.month_end, v_today))
                   order by m.month_start)
  into v_trend
  from (
    select gs::date as month_start, (gs + interval '1 month' - interval '1 day')::date as month_end
    from generate_series(date_trunc('month', p_to) - interval '5 months', date_trunc('month', p_to), interval '1 month') gs
  ) m;

  -- Balance snapshot, as of today.
  with stock as (
    select e."ItemCode", sum(e."Quantity") as qty
    from public."ItemLedgerEntries" e
    group by e."ItemCode"
    having sum(e."Quantity") > 0
  ),
  vendor_ap as (
    select coalesce((select sum(b."Amount") from public."VendorBills" b where not b."IsVoid"), 0)
         - coalesce((select sum(p."Amount") from public."VendorPayments" p where not p."IsVoid"), 0) as ap
  ),
  open_vendor_bills as (
    select b."BillNo", b."DueDate",
           b."Amount" - coalesce((select sum(p."Amount") from public."VendorPayments" p
                                  where p."BillNo" = b."BillNo" and not p."IsVoid"), 0) as open_amount
    from public."VendorBills" b
    where not b."IsVoid"
  ),
  bill_unpaid as (
    select b."BillID", b."Name", b."ExpectedAmount", d.due_date
    from public."BusinessBills" b
    cross join lateral public._business_bill_due_dates(b."FirstDueDate", b."Frequency", b."FirstDueDate", v_today + 30) d
    where b."IsActive"
      and not exists (select 1 from public."BusinessBillPayments" p
                      where p."BillID" = b."BillID" and p."DueDate" = d.due_date and not p."IsVoid")
  ),
  adv as (
    select a."TransactionNo",
           case when a."FullyPaid" then coalesce(a."NetAmount", 0)
                else greatest(coalesce(a."NetAmount", 0) - coalesce(a."Balance", 0), coalesce(a."Downpayment", 0)) end as deposit
    from public."AdvanceOrders" a
    where nullif(trim(coalesce(a."OnlineOrderID", '')), '') is null
  )
  select jsonb_build_object(
    'inventory_value', (select coalesce(round(sum(s.qty * coalesce(i."Cost", 0)), 2), 0)
                        from stock s left join public."Items" i on i."Code" = s."ItemCode"),
    'inventory_uncosted_items', (select count(*) from stock s left join public."Items" i on i."Code" = s."ItemCode"
                                 where coalesce(i."Cost", 0) = 0),
    -- Per "dont include Delivered / Shipped / Cancelled / New Status": only orders still in progress.
    'receivables', (select coalesce(sum(o."Balance"), 0) from public."OnlineOrders" o
                    where o."Balance" > 0 and o."ReceivedAtShop" is not true
                      and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled', 'delivered', 'shipped', 'new')),
    'receivables_count', (select count(*) from public."OnlineOrders" o
                          where o."Balance" > 0 and o."ReceivedAtShop" is not true
                            and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled', 'delivered', 'shipped', 'new')),
    'vendor_payables', (select greatest(ap, 0) from vendor_ap),
    'vendor_overdue', (select coalesce(sum(open_amount), 0) from open_vendor_bills
                       where open_amount > 0 and "DueDate" < v_today),
    'bills_overdue_amount', (select coalesce(sum("ExpectedAmount"), 0) from bill_unpaid where due_date < v_today),
    'bills_overdue_count', (select count(*) from bill_unpaid where due_date < v_today),
    'bills_due30_amount', (select coalesce(sum("ExpectedAmount"), 0) from bill_unpaid where due_date >= v_today),
    'bills_due30_count', (select count(*) from bill_unpaid where due_date >= v_today),
    'owed_to_owner', public._owner_loan_outstanding(),
    'customer_deposits', (select coalesce(sum(deposit), 0) from adv where deposit > 0),
    'customer_deposits_count', (select count(*) from adv where deposit > 0),
    'capital_total', (select coalesce(sum("Amount"), 0) from public."OwnerFundEntries"
                      where not "IsVoid" and "EntryType" = 'Capital In'),
    'drawings_total', (select coalesce(sum("Amount"), 0) from public."OwnerFundEntries"
                       where not "IsVoid" and "EntryType" = 'Drawing')
  ) into v_position;

  select jsonb_build_object(
    'capital_in', coalesce(sum("Amount") filter (where "EntryType" = 'Capital In'), 0),
    'owner_loan', coalesce(sum("Amount") filter (where "EntryType" = 'Owner Loan'), 0),
    'paid_directly', coalesce(sum("Amount") filter (where "Method" = 'Paid Directly'), 0),
    'drawings', coalesce(sum("Amount") filter (where "EntryType" = 'Drawing'), 0),
    'repayments', coalesce(sum("Amount") filter (where "EntryType" = 'Loan Repayment'), 0),
    'entries', count(*)
  ) into v_owner
  from public."OwnerFundEntries"
  where not "IsVoid" and "EntryDate" >= p_from and "EntryDate" <= p_to;

  select jsonb_build_object(
    'purchases', (select coalesce(sum(round(coalesce(l."UnitCost", 0) * coalesce(l."QtyReceived", 0), 2)), 0)
                  from public."PostedPurchaseOrderLines" l
                  join public."PostedPurchaseOrders" h on h."PONo" = l."PONo"
                  where (h."PostedAtUtc" at time zone 'Asia/Manila')::date between p_from and p_to),
    'vendor_payments', (select coalesce(sum(p."Amount"), 0) from public."VendorPayments" p
                        where not p."IsVoid" and p."PaymentDate" between p_from and p_to),
    'bills_paid_business', (select coalesce(sum(p."Amount"), 0) from public."BusinessBillPayments" p
                            where not p."IsVoid" and p."PaidBy" = 'Business' and p."PaidDate" between p_from and p_to),
    'bills_paid_owner', (select coalesce(sum(p."Amount"), 0) from public."BusinessBillPayments" p
                         where not p."IsVoid" and p."PaidBy" <> 'Business' and p."PaidDate" between p_from and p_to)
  ) into v_cash;

  with items as (
    select 'Bill'::text as kind, b."Name"::text as name, d.due_date, b."ExpectedAmount" as amount
    from public."BusinessBills" b
    cross join lateral public._business_bill_due_dates(b."FirstDueDate", b."Frequency", b."FirstDueDate", v_today + 30) d
    where b."IsActive"
      and not exists (select 1 from public."BusinessBillPayments" p
                      where p."BillID" = b."BillID" and p."DueDate" = d.due_date and not p."IsVoid")
    union all
    select 'Vendor', coalesce(v."Name", b."VendorCode")::text || ' · ' || b."BillNo", b."DueDate",
           b."Amount" - coalesce((select sum(p."Amount") from public."VendorPayments" p
                                  where p."BillNo" = b."BillNo" and not p."IsVoid"), 0)
    from public."VendorBills" b
    left join public."Vendors" v on v."VendorCode" = b."VendorCode"
    where not b."IsVoid" and b."DueDate" is not null and b."DueDate" <= v_today + 30
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'name', name, 'due_date', due_date, 'amount', amount)
                            order by due_date, name), '[]'::jsonb)
  into v_upcoming
  from (select * from items where kind = 'Bill' or amount > 0 order by due_date, name limit 25) t;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'today', v_today,
    'pnl', public._my_view_pnl(p_from, p_to),
    'prev', public._my_view_pnl(p_from - v_days, p_from - 1),
    'trend', coalesce(v_trend, '[]'::jsonb),
    'position', v_position,
    'owner', v_owner,
    'cash_out', v_cash,
    'upcoming', v_upcoming
  );
end;
$$;

grant execute on function public.admin_get_my_view(text, text, date, date) to anon;

-- ---------------------------------------------------------------------------
-- Drill-down: the individual entries behind one expense category in the Income Statement - per
-- "what is this others.. can we make it clickable so I can see?". p_code is the category code as
-- _my_view_pnl groups it ('(No category)' = blank category). Same two sources and date rules.
drop function if exists public.admin_list_my_view_expense_entries(text, text, date, date, text);

create or replace function public.admin_list_my_view_expense_entries(
  p_admin_username text,
  p_admin_password text,
  p_from date,
  p_to date,
  p_code text
)
returns table(source text, entry_date date, description text, amount numeric, doc_no text, warehouse text, created_by text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select * from (
      select 'POS'::text, e."Date", e."Description"::text, coalesce(e."NetAmount", 0), e."ReceiptNo"::text,
             e."Warehouse"::text, e."UserID"::text
      from public."ExpenseEntryHeader" e
      where e."Date" >= p_from and e."Date" <= p_to
        and coalesce(nullif(trim(e."ExpenseCategory"), ''), '(No category)') = p_code
      union all
      select 'Expense Journal', j."EntryDate", j."Description"::text, coalesce(j."Amount", 0), j."ReceiptNo"::text,
             j."Warehouse"::text, j."CreatedBy"::text
      from public."ExpenseJournalEntries" j
      where j."EntryDate" >= p_from and j."EntryDate" <= p_to
        and coalesce(nullif(trim(j."ExpenseCategory"), ''), '(No category)') = p_code
    ) t
    order by 2 desc, 4 desc
    limit 300;
end;
$$;

grant execute on function public.admin_list_my_view_expense_entries(text, text, date, date, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: should list admin_get_my_view, admin_list_my_view_expense_entries and _my_view_pnl.
select p.proname::text as function_name, pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('admin_get_my_view', '_my_view_pnl', 'admin_list_my_view_expense_entries')
order by 1;
