-- Daily Sales Report (daily-sales-report.html) - per "Do we have a daily sales reporting?" / "yes please".
--
-- One page for ANY day (not just today like the Dashboard cards): online + walk-in totals, per branch,
-- per tender, per category, per staff, the day's receipts, the POS cash count (Short/Over) and expenses,
-- plus yesterday / same day last week to compare.
--
-- Uses exactly the Dashboard's "today" rules, so picking today matches its cards to the peso:
--   * online  - ReceivedAtShop not true, ConfirmedAtUtc's Manila date (falls back to "Date"), not cancelled
--   * walk-in - ReceivedAtShop true, "Date" = the day, not cancelled
--   (admin_get_dashboard_daily_by_warehouse / admin_get_dashboard_daily_by_tender)
-- Unconfirmed "New" orders stay in AutomatedOrders until Confirm Order, so they're never counted.
--
--   sales     - MoneyToCollect (the order total after discount), same as the Dashboard headline
--   tenders   - OnlineOrderPayments per method, plus an "Unpaid / not synced yet" row so they add up to sales
--   categories- line GrossAmount, resolved variant -> item -> '(Uncategorized)' like the Category Sales report
--               (set components carry ₱0; delivery fees / discounts aren't lines, so this can differ from sales)
--   staff     - online: ConfirmedBy (else CreatedBy); walk-in: CreatedBy (the cashier)
--   cash      - TenderDeclarationHeader rows for the day (POS end-of-day count)
--   expenses  - ExpenseEntryHeader.NetAmount + ExpenseJournalEntries.Amount dated that day (per branch), and
--               expense_lines - each of those entries, for the page's clickable Expenses drill-down
--               Bills & Dues payments (journal entries linked from BusinessBillPayments - rent, utilities, loans...)
--               are left out, per "can you not include the bills and dues in the expense of daily sales report".
--   advance   - per "does walkin includes advance order?": advance orders live in AdvanceOrders, NOT OnlineOrders,
--               so they're in none of the figures above. advance_placed = orders placed that day (not voided);
--               advance_collected = AdvanceOrderPayments dated that day by tender (POS + portal payments, a void's
--               refund as a negative). Kept separate from sales - same as the Dashboard's advance card.
--               Two ways an advance order ALSO lands in the sales above, both flagged advance_copy = true:
--                 1. old ones the POS pushed to Pancake ("Advance Order Ref:" note) synced back into OnlineOrders;
--                 2. POS Pay In Full writes a SALES TransactionHeader for the grand total under the advance
--                    order's ReceiptNo (AdvanceOrdersHeaderForm), which SendFailedTransactionToCloud sends as a
--                    walk-in - matched on PosReceiptNo = AdvanceOrders.ReceiptNo at the same branch.
--               The page leaves flagged rows out of "Sales + Advance Collected" so that money isn't counted twice.
--
-- Returned as ONE jsonb value (never cut at the API's 1000-row cap); the page filters by branch client-side.
-- Super users only (is_admin_authorized), like the other finance reports.
-- Run AFTER supabase_payment_method_report.sql and supabase_tender_declaration_tables.sql. Safe to re-run.

-- Online + walk-in totals for one day, same rules as above - used for the yesterday / last-week compare.
drop function if exists public._daily_sales_totals(date);

create or replace function public._daily_sales_totals(p_date date)
returns table(online_sales numeric, online_count int, walkin_sales numeric, walkin_count int)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    coalesce(sum(o."MoneyToCollect") filter (
      where o."ReceivedAtShop" is not true
        and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = p_date), 0)::numeric,
    count(*) filter (
      where o."ReceivedAtShop" is not true
        and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = p_date)::int,
    coalesce(sum(o."MoneyToCollect") filter (where o."ReceivedAtShop" is true and o."Date" = p_date), 0)::numeric,
    count(*) filter (where o."ReceivedAtShop" is true and o."Date" = p_date)::int
  from public."OnlineOrders" o
  where lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
    and (o."Date" = p_date
         or (o."ConfirmedAtUtc" >= (p_date::timestamp at time zone 'Asia/Manila')
             and o."ConfirmedAtUtc" < ((p_date + 1)::timestamp at time zone 'Asia/Manila')));
$$;

revoke all on function public._daily_sales_totals(date) from public, anon, authenticated;

drop function if exists public.admin_get_daily_sales_report(text, text, date);

create or replace function public.admin_get_daily_sales_report(
  p_admin_username text,
  p_admin_password text,
  p_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_result jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_date is null then
    raise exception 'Pick a date.';
  end if;

  with orders as (
    select o."OrderID" as order_id,
           coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
           coalesce(o."ReceivedAtShop", false) as walkin,
           coalesce(o."MoneyToCollect", 0) as total,
           coalesce(o."Discount", 0) as discount,
           coalesce(o."AmountPaid", 0) as paid,
           coalesce(o."Balance", 0) as balance,
           o."PosReceiptNo" as receipt_no,
           o."Time" as order_time,
           o."ConfirmedAtUtc" as confirmed_at,
           o."Status" as status,
           coalesce(nullif(trim(o."WalkinCustomerName"), ''), nullif(trim(o."CustomerName"), '')) as customer,
           coalesce(o."ForDelivery", false) as for_delivery,
           (coalesce(o."Note", '') ilike '%Advance Order Ref:%'
            or (o."ReceivedAtShop" is true and o."PosReceiptNo" is not null and exists (
                  select 1 from public."AdvanceOrders" a
                  where a."ReceiptNo" = o."PosReceiptNo" and a."Warehouse" is not distinct from w."Name"))) as advance_copy,
           case when coalesce(o."ReceivedAtShop", false)
                then coalesce(nullif(trim(o."CreatedBy"), ''), '(Unknown)')
                else coalesce(nullif(trim(o."ConfirmedBy"), ''), nullif(trim(o."CreatedBy"), ''), '(Unknown)')
           end as staff
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      and (o."Date" = p_date
           or (o."ConfirmedAtUtc" >= (p_date::timestamp at time zone 'Asia/Manila')
               and o."ConfirmedAtUtc" < ((p_date + 1)::timestamp at time zone 'Asia/Manila')))
      and (
        (o."ReceivedAtShop" is true and o."Date" = p_date)
        or (o."ReceivedAtShop" is not true
            and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = p_date)
      )
  ),
  pays as (
    select x.order_id, x.wh, x.walkin, p."MethodCode" as code, p."Amount" as amount
    from orders x
    join public."OnlineOrderPayments" p on p."OrderID" = x.order_id
  ),
  tenders as (
    select pd.wh, pd.walkin, public._payment_method_label(pd.code)::text as method,
           sum(pd.amount) as amount, count(distinct pd.order_id) as cnt
    from pays pd
    group by pd.wh, pd.walkin, pd.code
    union all
    select x.wh, x.walkin, 'Unpaid / not synced yet',
           sum(x.total) - coalesce((select sum(pd.amount) from pays pd where pd.wh = x.wh and pd.walkin = x.walkin), 0),
           count(*) filter (where not exists (select 1 from pays pd where pd.order_id = x.order_id))
    from orders x
    group by x.wh, x.walkin
  ),
  cats as (
    select x.wh, x.walkin,
           coalesce(nullif(trim(v."CategoryCode"), ''), nullif(trim(i."CategoryCode"), ''), '(Uncategorized)') as cat,
           coalesce(l."Quantity", 0) as qty,
           coalesce(l."GrossAmount", 0) as amount
    from orders x
    join public."OnlineOrderLines" l on l."OrderID" = x.order_id
    left join public."Variants" v on v."VariationId" = l."VariationId"
    left join public."Items" i on i."Code" = coalesce(nullif(trim(v."MainItemCode"), ''), nullif(trim(v."ItemCode"), ''), nullif(trim(l."ItemCode"), ''))
  ),
  exp as (
    select coalesce(nullif(trim(e.wh), ''), '(No warehouse)') as wh, sum(e.amount) as amount, count(*) as cnt
    from (
      select h."Warehouse" as wh, h."NetAmount" as amount
      from public."ExpenseEntryHeader" h where h."Date" = p_date
      union all
      select j."Warehouse", j."Amount"
      from public."ExpenseJournalEntries" j where j."EntryDate" = p_date
        and not exists (select 1 from public."BusinessBillPayments" bp where bp."ExpenseJournalEntryID" = j."EntryID")
    ) e
    group by 1
  )
  select jsonb_build_object(
    'date', p_date,
    'compare', (
      select jsonb_build_object(
        'yesterday', (select to_jsonb(t) from public._daily_sales_totals(p_date - 1) t),
        'last_week', (select to_jsonb(t) from public._daily_sales_totals(p_date - 7) t)
      )
    ),
    'orders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'order_id', x.order_id, 'receipt_no', x.receipt_no, 'time', x.order_time,
               'confirmed_at', x.confirmed_at, 'warehouse', x.wh, 'is_walkin', x.walkin,
               'customer', x.customer, 'staff', x.staff, 'status', x.status, 'for_delivery', x.for_delivery,
               'advance_copy', x.advance_copy,
               'total', x.total, 'discount', x.discount, 'paid', x.paid, 'balance', x.balance,
               'payments', (select string_agg(public._payment_method_label(pd.code) || ' ' || to_char(pd.amount, 'FM999,999,990.00'), ', ')
                            from pays pd where pd.order_id = x.order_id)
             ) order by x.walkin, coalesce(x.confirmed_at::text, x.order_time), x.order_id)
      from orders x), '[]'::jsonb),
    'tenders', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', t.wh, 'is_walkin', t.walkin, 'method', t.method,
                                          'amount', t.amount, 'order_count', t.cnt) order by t.amount desc)
      from tenders t where t.amount <> 0), '[]'::jsonb),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', c.wh, 'is_walkin', c.walkin, 'category', c.name,
                                          'qty', c.qty, 'revenue', c.revenue) order by c.revenue desc)
      from (
        select k.wh, k.walkin, coalesce(nullif(trim(cg."Description"), ''), k.cat) as name,
               sum(k.qty) as qty, sum(k.amount) as revenue
        from cats k
        left join public."Categories" cg on cg."Code" = k.cat
        group by k.wh, k.walkin, 3
      ) c), '[]'::jsonb),
    'cash', coalesce((
      select jsonb_agg(jsonb_build_object(
               'warehouse', h."Warehouse", 'eod_id', h."EODID", 'user_id', h."UserID", 'time', h."DeclTime",
               'float', h."FloatAmount", 'cash_sales', h."CashSales", 'expected', h."ExpectedCash",
               'declared', h."DeclaredCash", 'variance', h."Variance", 'reason', h."VarianceReason"
             ) order by h."Warehouse", h."DeclTime")
      from public."TenderDeclarationHeader" h
      where h."DeclDate" = p_date), '[]'::jsonb),
    'expenses', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', e.wh, 'amount', e.amount, 'count', e.cnt) order by e.wh)
      from exp e), '[]'::jsonb),
    -- The entries behind 'expenses' (same two sources, same day), for the page's clickable Expenses drill-down.
    'expense_lines', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.warehouse, x.entry_time nulls last, x.ref)
      from (
        select 'POS'::text as source, h."ReceiptNo"::text as ref, h."Time"::text as entry_time,
               coalesce(nullif(trim(h."Warehouse"), ''), '(No warehouse)') as warehouse,
               h."ExpenseCategory"::text as category, h."Description"::text as description,
               h."UserID"::text as staff, coalesce(h."NetAmount", 0) as amount
        from public."ExpenseEntryHeader" h where h."Date" = p_date
        union all
        select 'Journal', null, to_char(j."CreatedAtUtc" at time zone 'Asia/Manila', 'HH24:MI'),
               coalesce(nullif(trim(j."Warehouse"), ''), '(No warehouse)'),
               j."ExpenseCategory", j."Description", j."CreatedBy", j."Amount"
        from public."ExpenseJournalEntries" j where j."EntryDate" = p_date
        and not exists (select 1 from public."BusinessBillPayments" bp where bp."ExpenseJournalEntryID" = j."EntryID")
      ) x), '[]'::jsonb),
    -- Advance orders PLACED this day (voided left out) - same as the Dashboard's "Today's Advance Orders" card.
    'advance_placed', coalesce((
      select jsonb_agg(jsonb_build_object(
               'transaction_no', a."TransactionNo", 'receipt_no', a."ReceiptNo", 'time', a."Time",
               'warehouse', coalesce(nullif(trim(a."Warehouse"), ''), '(No warehouse)'),
               'customer', a."CustomerName", 'description', a."Order_Description", 'staff', a."UserID",
               'net', coalesce(a."NetAmount", 0), 'downpayment', coalesce(a."Downpayment", 0),
               'balance', greatest(coalesce(a."Balance", 0), 0)
             ) order by a."Time", a."TransactionNo")
      from public."AdvanceOrders" a
      where a."Date" = p_date and not coalesce(a."IsVoid", false)), '[]'::jsonb),
    -- Advance-order money COLLECTED this day on any advance order (downpayments, balances, portal Mark Fully
    -- Paid / delivery remits, and a void's refund as a negative) - same as the Dashboard's "Collected today -
    -- by tender" and the POS EOD "ADV ORDER COLLECTIONS". Voided orders are NOT filtered, on purpose.
    'advance_collected', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', c.wh, 'tender', c.tender, 'amount', c.amount,
                                          'payment_count', c.cnt) order by c.amount desc)
      from (
        select coalesce(nullif(trim(coalesce(a."Warehouse", p."Warehouse")), ''), '(No warehouse)') as wh,
               coalesce(nullif(upper(trim(p."TenderTypeCode")), ''), '(No tender)') as tender,
               sum(coalesce(p."Amount", 0)) as amount, count(*) as cnt
        from public."AdvanceOrderPayments" p
        left join public."AdvanceOrders" a on a."TransactionNo" = p."AdvanceTransactionNo"
        where p."Date" = p_date
        group by 1, 2
      ) c), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

grant execute on function public.admin_get_daily_sales_report(text, text, date) to anon;

notify pgrst, 'reload schema';
