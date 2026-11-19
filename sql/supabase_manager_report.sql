-- Manager's Report (manager-report.html) - per "can you give me a manager's report.. i want to see how my store
-- is doing like are we losing? are we selling? how much? is the inventory losing anything? i want to see items
-- inventory / sold and missing something like that. target sales and sales as of the month".
--
-- One month on one page, per branch (the page filters by branch client-side, so switching never re-queries):
--   1. SALES vs TARGET - sales use the SAME rules as the Daily / Monthly Sales Report (online by ConfirmedAtUtc's
--      Manila date, walk-in by "Date", cancelled left out, MoneyToCollect), so the month total matches the
--      Monthly Sales Report. Targets are set per branch per month on the page (new table "SalesTargets").
--   2. MONEY IN vs MONEY OUT ("are we losing?") - cash view, because most items have no cost yet:
--        in  = sales (advance-order copies taken out) + advance-order payments collected
--        out = posted purchase orders (UnitCost x QtyReceived by OrderDate, same as Purchases & Expenses)
--              + POS expenses + Expense Journal (bills included - they are real money out)
--              + payroll (finalized runs' NetPay + cash advances released; company-wide, most staff have no branch)
--      Gross margin is also returned, but only for lines whose item has a cost (Items."Cost", else the latest
--      posted PO unit cost); the uncosted share is returned too so the page can say how much is unknown.
--   3. INVENTORY - Item Ledger movements in the month per item x branch, bucketed: purchased, produced,
--      transfer in / out, sold, used in store (POS expense), count found / count MISSING (physical counts),
--      adjusted + / -, with opening and closing qty. Valued at the same unit cost. Plus cash short/over from
--      the POS cash counts, defect reports, transfers shipped but not received, and negative stock.
-- The pseudo item INC_EXP and the TESTING* warehouses are left out.
--
-- Super users only (is_admin_authorized). Run AFTER supabase_monthly_sales_report.sql (uses
-- _sales_totals_by_branch). Safe to re-run. Needs manager-report.html / js/managerReport.js ?v=manager1.
-- Ends with ONE result.

create table if not exists public."SalesTargets" (
  "Month" date not null,
  "Warehouse" text not null,
  "TargetAmount" numeric not null default 0,
  "UpdatedBy" text,
  "UpdatedAtUtc" timestamptz not null default now(),
  primary key ("Month", "Warehouse")
);

-- Only reached through the security-definer functions below.
alter table public."SalesTargets" enable row level security;
revoke all on table public."SalesTargets" from anon, authenticated;

-- Save (or clear, with null / 0) one branch's target for a month.
drop function if exists public.admin_set_sales_target(text, text, date, text, numeric);

create or replace function public.admin_set_sales_target(
  p_admin_username text,
  p_admin_password text,
  p_month date,
  p_warehouse text,
  p_amount numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month date := date_trunc('month', p_month)::date;
  v_wh text := nullif(trim(p_warehouse), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_month is null or v_wh is null then
    raise exception 'Pick a month and a branch.';
  end if;
  if coalesce(p_amount, 0) < 0 then
    raise exception 'Target cannot be negative.';
  end if;

  if coalesce(p_amount, 0) = 0 then
    delete from public."SalesTargets" where "Month" = v_month and "Warehouse" = v_wh;
  else
    insert into public."SalesTargets" ("Month", "Warehouse", "TargetAmount", "UpdatedBy", "UpdatedAtUtc")
    values (v_month, v_wh, round(p_amount, 2), p_admin_username, now())
    on conflict ("Month", "Warehouse") do update
      set "TargetAmount" = excluded."TargetAmount", "UpdatedBy" = excluded."UpdatedBy", "UpdatedAtUtc" = now();
  end if;
end;
$$;

grant execute on function public.admin_set_sales_target(text, text, date, text, numeric) to anon;

-- The whole month's data, no auth check - private, only called by admin_get_manager_report (everything) and
-- staff_get_manager_scorecard (supabase_manager_scorecard.sql - one branch, money taken out).
create or replace function public._manager_report_data(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_from date;
  v_to date;     -- exclusive
  v_end date;    -- exclusive, clipped to tomorrow for the current month
  v_days int;
  v_prev_from date;
  v_prev_to date;
  v_ly_from date;
  v_ly_to date;
  v_result jsonb;
begin
  if p_month is null then
    raise exception 'Pick a month.';
  end if;

  v_from := date_trunc('month', p_month)::date;
  v_to := (v_from + interval '1 month')::date;
  v_end := least(v_to, v_today + 1);
  v_days := greatest(v_end - v_from, 0);
  v_prev_from := (v_from - interval '1 month')::date;
  v_prev_to := least(v_prev_from + v_days, v_from);
  v_ly_from := (v_from - interval '1 year')::date;
  v_ly_to := least(v_ly_from + v_days, (v_ly_from + interval '1 month')::date);

  with wh as (
    select w."ID"::text as id, coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as name
    from public."Warehouses" w
  ),
  -- Unit cost per item: Items."Cost", else the latest posted PO unit cost (QtyReceived is in base units).
  po_cost as (
    select distinct on (l."ItemCode") l."ItemCode" as code, l."UnitCost" as cost
    from public."PostedPurchaseOrderLines" l
    join public."PostedPurchaseOrders" h on h."PONo" = l."PONo"
    where coalesce(l."UnitCost", 0) > 0 and coalesce(l."QtyReceived", 0) > 0
    order by l."ItemCode", h."OrderDate" desc, l."EntryNo" desc
  ),
  unit_cost as (
    select i."Code" as code, coalesce(nullif(i."Cost", 0), pc.cost) as cost
    from public."Items" i
    left join po_cost pc on pc.code = i."Code"
  ),
  orders as (
    select o."OrderID" as order_id,
           coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
           coalesce(o."ReceivedAtShop", false) as walkin,
           case when o."ReceivedAtShop" is true then o."Date"
                else coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") end as day,
           coalesce(o."MoneyToCollect", 0) as total,
           (coalesce(o."Note", '') ilike '%Advance Order Ref:%'
            or (o."ReceivedAtShop" is true and o."PosReceiptNo" is not null and exists (
                  select 1 from public."AdvanceOrders" a
                  where a."ReceiptNo" = o."PosReceiptNo" and a."Warehouse" is not distinct from w."Name"))) as advance_copy
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      and ((o."Date" >= v_from and o."Date" < v_to)
           or (o."ConfirmedAtUtc" >= (v_from::timestamp at time zone 'Asia/Manila')
               and o."ConfirmedAtUtc" < (v_to::timestamp at time zone 'Asia/Manila')))
      and (
        (o."ReceivedAtShop" is true and o."Date" >= v_from and o."Date" < v_to)
        or (o."ReceivedAtShop" is not true
            and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") >= v_from
            and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") < v_to)
      )
      and coalesce(w."Name", '') not ilike 'TESTING%'
  ),
  lines as (
    select x.wh, l."ItemCode" as code,
           coalesce(l."Quantity", 0) as qty,
           coalesce(br."Revenue", l."GrossAmount", 0) as revenue,
           -- Custom builds (bundle share) have no single item cost.
           case when br."OrderID" is null then uc.cost end as cost
    from orders x
    join public."OnlineOrderLines" l on l."OrderID" = x.order_id
    left join public."OnlineOrderLineBundleRevenue" br on br."OrderID" = l."OrderID" and br."LineID" = l."LineID"
    left join unit_cost uc on uc.code = l."ItemCode"
  ),
  ile as (
    select e."ItemCode" as code, coalesce(w.name, '(No warehouse)') as wh, e."PostingDate" as day,
           e."EntryType" as etype, coalesce(e."DocumentType", '') as dtype, e."Quantity" as qty
    from public."ItemLedgerEntries" e
    left join wh w on w.id = e."WarehouseId"
    where e."PostingDate" < v_to
      and e."ItemCode" <> 'INC_EXP'
      and coalesce(w.name, '') not ilike 'TESTING%'
  ),
  moves as (
    select m.code, m.wh,
           sum(m.qty) filter (where m.day < v_from) as opening,
           sum(m.qty) filter (where m.day >= v_from and m.etype = 'Purchase') as purchased,
           sum(m.qty) filter (where m.day >= v_from and m.etype = 'Output') as produced,
           sum(m.qty) filter (where m.day >= v_from and m.etype = 'Transfer' and m.qty > 0) as transfer_in,
           -sum(m.qty) filter (where m.day >= v_from and m.etype = 'Transfer' and m.qty < 0) as transfer_out,
           -sum(m.qty) filter (where m.day >= v_from and m.etype = 'Sale') as sold,
           -sum(m.qty) filter (where m.day >= v_from and m.dtype = 'POS Expense') as used,
           sum(m.qty) filter (where m.day >= v_from and m.dtype in ('Phys. Inventory', 'Serial Phys. Inventory') and m.qty > 0) as found,
           -sum(m.qty) filter (where m.day >= v_from and m.dtype in ('Phys. Inventory', 'Serial Phys. Inventory') and m.qty < 0) as missing,
           sum(m.qty) filter (where m.day >= v_from and m.etype like '%Adjmt.%' and m.dtype not in ('Phys. Inventory', 'Serial Phys. Inventory', 'POS Expense') and m.qty > 0) as adj_plus,
           -sum(m.qty) filter (where m.day >= v_from and m.etype like '%Adjmt.%' and m.dtype not in ('Phys. Inventory', 'Serial Phys. Inventory', 'POS Expense') and m.qty < 0) as adj_minus,
           sum(m.qty) as closing
    from ile m
    group by m.code, m.wh
  ),
  -- Transfers whose shipments and receipts don't net to zero (still in transit, or received more/less).
  transfer_gaps as (
    select e."DocumentNo" as doc,
           min(e."PostingDate") as shipped_date,
           max(e."PostingDate") filter (where e."Quantity" > 0) as received_date,
           -sum(e."Quantity") filter (where e."Quantity" < 0) as shipped,
           coalesce(sum(e."Quantity") filter (where e."Quantity" > 0), 0) as received,
           sum(e."Quantity" * coalesce(uc.cost, 0)) as value
    from public."ItemLedgerEntries" e
    left join unit_cost uc on uc.code = e."ItemCode"
    where e."EntryType" = 'Transfer' and e."PostingDate" < v_to
    group by e."DocumentNo"
    having sum(e."Quantity") <> 0
  ),
  exp as (
    select coalesce(nullif(trim(e.wh), ''), '(No warehouse)') as wh,
           coalesce(nullif(trim(e.category), ''), '(No category)') as category, e.amount
    from (
      select h."Warehouse" as wh, h."ExpenseCategory"::text as category, coalesce(h."NetAmount", 0) as amount
      from public."ExpenseEntryHeader" h where h."Date" >= v_from and h."Date" < v_to
      union all
      select j."Warehouse", j."ExpenseCategory"::text, coalesce(j."Amount", 0)
      from public."ExpenseJournalEntries" j where j."EntryDate" >= v_from and j."EntryDate" < v_to
    ) e
    where coalesce(e.wh, '') not ilike 'TESTING%'
  )
  select jsonb_build_object(
    'month', v_from,
    'month_end', v_to - 1,
    'through', v_end - 1,
    'days_in_month', v_to - v_from,
    'days_elapsed', v_days,
    'warehouses', coalesce((
      select jsonb_agg(n order by n) from (
        select distinct w.name as n from wh w where w.name not ilike 'TESTING%'
      ) z), '[]'::jsonb),
    'targets', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', t."Warehouse", 'target', t."TargetAmount",
                                          'updated_by', t."UpdatedBy", 'updated_at', t."UpdatedAtUtc"))
      from public."SalesTargets" t where t."Month" = v_from), '[]'::jsonb),
    'prev_targets', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', t."Warehouse", 'target', t."TargetAmount"))
      from public."SalesTargets" t where t."Month" = v_prev_from), '[]'::jsonb),
    -- Day-by-day sales per branch (for the pace chart and the month total).
    'sales_days', coalesce((
      select jsonb_agg(jsonb_build_object('date', d.day, 'warehouse', d.wh, 'amount', d.amount, 'count', d.cnt,
                                          'walkin', d.walkin, 'advance_copy', d.adv) order by d.day, d.wh)
      from (
        select x.day, x.wh, sum(x.total) as amount, count(*) as cnt,
               coalesce(sum(x.total) filter (where x.walkin), 0) as walkin,
               coalesce(sum(x.total) filter (where x.advance_copy), 0) as adv
        from orders x group by 1, 2
      ) d), '[]'::jsonb),
    'compare', jsonb_build_object(
      'prev_from', v_prev_from, 'prev_to', v_prev_to - 1,
      'ly_from', v_ly_from, 'ly_to', v_ly_to - 1,
      'prev', coalesce((select jsonb_agg(jsonb_build_object('warehouse', t.warehouse, 'amount', t.online_sales + t.walkin_sales))
                        from public._sales_totals_by_branch(v_prev_from, v_prev_to) t), '[]'::jsonb),
      'prev_full', coalesce((select jsonb_agg(jsonb_build_object('warehouse', t.warehouse, 'amount', t.online_sales + t.walkin_sales))
                             from public._sales_totals_by_branch(v_prev_from, v_from) t), '[]'::jsonb),
      'last_year', coalesce((select jsonb_agg(jsonb_build_object('warehouse', t.warehouse, 'amount', t.online_sales + t.walkin_sales))
                             from public._sales_totals_by_branch(v_ly_from, v_ly_to) t), '[]'::jsonb)
    ),
    -- Gross margin where the item cost is known. Lines with no revenue (set parts - the money is on the set
    -- line) and lines whose cost is over 3x the selling price (cost entered per pack / roll while sold per piece)
    -- are left out of the margin; the second kind is listed under 'below_cost' as suspect.
    'margin', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', g.wh, 'costed_revenue', g.cr, 'cogs', g.cogs,
                                          'uncosted_revenue', g.ur, 'uncosted_lines', g.ul, 'suspect_revenue', g.sr))
      from (
        select k.wh,
               coalesce(sum(k.revenue) filter (where k.cls = 'costed'), 0) as cr,
               coalesce(sum(k.qty * k.cost) filter (where k.cls = 'costed'), 0) as cogs,
               coalesce(sum(k.revenue) filter (where k.cls = 'uncosted'), 0) as ur,
               count(*) filter (where k.cls = 'uncosted') as ul,
               coalesce(sum(k.revenue) filter (where k.cls = 'suspect'), 0) as sr
        from (
          select l2.*,
                 case when l2.revenue <= 0 or l2.qty <= 0 then 'no_revenue'
                      when coalesce(l2.cost, 0) = 0 then 'uncosted'
                      when l2.cost > 3 * (l2.revenue / l2.qty) then 'suspect'
                      else 'costed' end as cls
          from lines l2
        ) k group by k.wh
      ) g), '[]'::jsonb),
    -- Items sold for less than their cost this month (suspect = cost over 3x the price, likely a unit mistake).
    'below_cost', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', b.wh, 'code', b.code, 'name', b.name, 'qty', b.qty,
                                          'revenue', b.revenue, 'unit_cost', b.cost,
                                          'suspect', b.cost > 3 * (b.revenue / b.qty)) order by b.qty * b.cost - b.revenue desc)
      from (
        select k.wh, k.code, coalesce(nullif(trim(i."Name"), ''), k.code) as name, k.cost,
               sum(k.qty) as qty, sum(k.revenue) as revenue
        from lines k left join public."Items" i on i."Code" = k.code
        where k.cost > 0 and k.revenue > 0 and k.qty > 0
        group by k.wh, k.code, i."Name", k.cost
        having sum(k.qty) * k.cost > sum(k.revenue)
      ) b), '[]'::jsonb),
    'top_items', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', t.wh, 'code', t.code, 'name', t.name, 'qty', t.qty, 'revenue', t.revenue)
                       order by t.revenue desc)
      from (
        select k.wh, k.code, coalesce(nullif(trim(i."Name"), ''), k.code) as name, sum(k.qty) as qty, sum(k.revenue) as revenue,
               row_number() over (partition by k.wh order by sum(k.revenue) desc) as rn
        from lines k left join public."Items" i on i."Code" = k.code
        group by k.wh, k.code, i."Name"
      ) t where t.rn <= 15), '[]'::jsonb),
    'advance_collected', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', c.wh, 'amount', c.amount))
      from (
        select coalesce(nullif(trim(coalesce(a."Warehouse", p."Warehouse")), ''), '(No warehouse)') as wh,
               sum(coalesce(p."Amount", 0)) as amount
        from public."AdvanceOrderPayments" p
        left join public."AdvanceOrders" a on a."TransactionNo" = p."AdvanceTransactionNo"
        where p."Date" >= v_from and p."Date" < v_to
        group by 1
      ) c), '[]'::jsonb),
    'purchases', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', p.wh, 'amount', p.amount, 'po_count', p.cnt))
      from (
        select coalesce(nullif(trim(l."WarehouseName"), ''), nullif(trim(h."WarehouseName"), ''), '(No warehouse)') as wh,
               sum(round(coalesce(l."UnitCost", 0) * coalesce(l."QtyReceived", 0), 2)) as amount,
               count(distinct l."PONo") as cnt
        from public."PostedPurchaseOrderLines" l
        join public."PostedPurchaseOrders" h on h."PONo" = l."PONo"
        where h."OrderDate" >= v_from and h."OrderDate" < v_to and coalesce(l."QtyReceived", 0) > 0
        group by 1
      ) p), '[]'::jsonb),
    'expenses', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', e.wh, 'category', e.category, 'amount', e.amount) order by e.amount desc)
      from (select wh, category, sum(amount) as amount from exp group by 1, 2) e), '[]'::jsonb),
    -- Finalized payroll paid out in the month (NetPay) + cash advances released (company-wide).
    'payroll', jsonb_build_object(
      'net_pay', coalesce((select sum(le."Amount") from public."PayrollLedgerEntries" le
                           where le."EntryType" = 'NetPay' and coalesce(le."PayDate", le."PeriodEnd") >= v_from
                             and coalesce(le."PayDate", le."PeriodEnd") < v_to), 0),
      'cash_advance', coalesce((select sum(le."Amount") from public."PayrollLedgerEntries" le
                                where le."EntryType" = 'CashAdvance' and coalesce(le."PayDate", le."PeriodEnd") >= v_from
                                  and coalesce(le."PayDate", le."PeriodEnd") < v_to), 0)
    ),
    'cash', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', c.wh, 'counts', c.cnt, 'short', c.short, 'over', c.over,
                                          'short_days', c.short_days))
      from (
        select coalesce(nullif(trim(h."Warehouse"), ''), '(No warehouse)') as wh, count(*) as cnt,
               sum(least(coalesce(h."Variance", 0), 0)) as short,
               sum(greatest(coalesce(h."Variance", 0), 0)) as over,
               count(*) filter (where coalesce(h."Variance", 0) < 0) as short_days
        from public."TenderDeclarationHeader" h
        where h."DeclDate" >= v_from and h."DeclDate" < v_to
        group by 1
      ) c), '[]'::jsonb),
    -- Per item x branch: opening, the month's movements, closing (only items that moved or hold stock).
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', m.code, 'name', coalesce(nullif(trim(i."Name"), ''), m.code),
               'category', coalesce(nullif(trim(cg."Description"), ''), i."CategoryCode"),
               'warehouse', m.wh, 'cost', uc.cost,
               'opening', coalesce(m.opening, 0), 'purchased', coalesce(m.purchased, 0), 'produced', coalesce(m.produced, 0),
               'transfer_in', coalesce(m.transfer_in, 0), 'transfer_out', coalesce(m.transfer_out, 0),
               'sold', coalesce(m.sold, 0), 'used', coalesce(m.used, 0),
               'found', coalesce(m.found, 0), 'missing', coalesce(m.missing, 0),
               'adj_plus', coalesce(m.adj_plus, 0), 'adj_minus', coalesce(m.adj_minus, 0),
               'closing', coalesce(m.closing, 0)))
      from moves m
      left join public."Items" i on i."Code" = m.code
      left join public."Categories" cg on cg."Code" = i."CategoryCode"
      left join unit_cost uc on uc.code = m.code
      where coalesce(m.closing, 0) <> 0 or coalesce(m.opening, 0) <> 0
         or m.purchased is not null or m.produced is not null or m.transfer_in is not null or m.transfer_out is not null
         or m.sold is not null or m.used is not null or m.found is not null or m.missing is not null
         or m.adj_plus is not null or m.adj_minus is not null), '[]'::jsonb),
    'transfer_gaps', coalesce((
      select jsonb_agg(jsonb_build_object('doc', g.doc, 'from', h."From Warehouse", 'to', h."To Warehouse",
                                          'status', h."Status", 'shipped_date', g.shipped_date, 'received_date', g.received_date,
                                          'shipped', g.shipped, 'received', g.received, 'value', g.value) order by g.shipped_date)
      from transfer_gaps g
      left join public."Transfer_Header" h on h."No." = g.doc), '[]'::jsonb),
    'defects', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', d.wh, 'status', d.status, 'count', d.cnt, 'qty', d.qty, 'value', d.value))
      from (
        select coalesce(w.name, '(No warehouse)') as wh, coalesce(r."Status", '(none)') as status,
               count(*) as cnt, sum(coalesce(r."Quantity", 0)) as qty, sum(coalesce(r."Quantity", 0) * coalesce(uc.cost, 0)) as value
        from public."DefectReports" r
        left join wh w on w.id = r."WarehouseId"::text
        left join unit_cost uc on uc.code = r."ItemCode"
        where (r."ReportedAtUtc" at time zone 'Asia/Manila')::date >= v_from
          and (r."ReportedAtUtc" at time zone 'Asia/Manila')::date < v_to
        group by 1, 2
      ) d), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

revoke all on function public._manager_report_data(date) from public, anon, authenticated;

drop function if exists public.admin_get_manager_report(text, text, date);

create or replace function public.admin_get_manager_report(
  p_admin_username text,
  p_admin_password text,
  p_month date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return public._manager_report_data(p_month);
end;
$$;

grant execute on function public.admin_get_manager_report(text, text, date) to anon;

notify pgrst, 'reload schema';

-- Check - one result.
select 'targets table' as section,
       case when to_regclass('public."SalesTargets"') is not null then 'ready' else 'MISSING' end as value
union all
select 'report function',
       case when to_regprocedure('public.admin_get_manager_report(text, text, date)') is not null then 'ready' else 'MISSING' end
union all
select 'save target function',
       case when to_regprocedure('public.admin_set_sales_target(text, text, date, text, numeric)') is not null then 'ready' else 'MISSING' end
union all
select 'needs monthly sales helper',
       case when to_regprocedure('public._sales_totals_by_branch(date, date)') is not null then 'ok' else 'RUN supabase_monthly_sales_report.sql' end;
