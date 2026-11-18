-- Monthly Sales Report (monthly-sales-report.html) - per "can we build monthly sales report then i want to filter
-- it out by the month and by warehouse".
--
-- The Daily Sales Report rolled up to a whole month, using the SAME rules (admin_get_daily_sales_report, latest
-- def in supabase_custom_aquarium_part_revenue.sql), so a month's total = the sum of its Daily Sales Reports:
--   * online  - ReceivedAtShop not true, ConfirmedAtUtc's Manila date (falls back to "Date"), not cancelled
--   * walk-in - ReceivedAtShop true, "Date" in the month, not cancelled
--   * sales = MoneyToCollect; categories use the custom aquarium bundle share (OnlineOrderLineBundleRevenue)
--   * expenses = POS expenses + Expense Journal, Bills & Dues payments left out
--   * advance orders kept apart (placed / collected), advance_copy sales flagged so they're not counted twice
--
-- Everything comes back already summed per branch (and per day for the day-by-day table), never per receipt,
-- so a busy month stays small. The page filters by branch client-side; clicking a day opens that day's
-- Daily Sales Report for the receipts.
--
-- p_month = any day in the month. The current month runs to today, and the "previous month" compare uses the
-- same number of days (Nov 1-17 vs Oct 1-17) so a half-finished month isn't compared to a full one.
--
-- Super users only (is_admin_authorized), like the Daily Sales Report.
-- Run AFTER supabase_custom_aquarium_part_revenue.sql. Safe to re-run. Needs monthly-sales-report.html /
-- js/monthlySalesReport.js ?v=monthsales1. Ends with ONE result.

-- Online / walk-in totals per branch for a date range [p_from, p_to) - used for the compare figures.
create or replace function public._sales_totals_by_branch(p_from date, p_to date)
returns table(warehouse text, online_sales numeric, online_count int, walkin_sales numeric, walkin_count int)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(nullif(trim(w."Name"), ''), '(No warehouse)')::text,
         coalesce(sum(o."MoneyToCollect") filter (where o."ReceivedAtShop" is not true), 0)::numeric,
         (count(*) filter (where o."ReceivedAtShop" is not true))::int,
         coalesce(sum(o."MoneyToCollect") filter (where o."ReceivedAtShop" is true), 0)::numeric,
         (count(*) filter (where o."ReceivedAtShop" is true))::int
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
    and ((o."Date" >= p_from and o."Date" < p_to)
         or (o."ConfirmedAtUtc" >= (p_from::timestamp at time zone 'Asia/Manila')
             and o."ConfirmedAtUtc" < (p_to::timestamp at time zone 'Asia/Manila')))
    and (
      (o."ReceivedAtShop" is true and o."Date" >= p_from and o."Date" < p_to)
      or (o."ReceivedAtShop" is not true
          and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") >= p_from
          and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") < p_to)
    )
  group by 1;
$$;

revoke all on function public._sales_totals_by_branch(date, date) from public, anon, authenticated;

drop function if exists public.admin_get_monthly_sales_report(text, text, date);

create or replace function public.admin_get_monthly_sales_report(
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
declare
  v_from date;
  v_to date;          -- exclusive
  v_end date;         -- exclusive, clipped to tomorrow for the current month
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_days int;
  v_prev_from date;
  v_prev_to date;
  v_ly_from date;
  v_ly_to date;
  v_result jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_month is null then
    raise exception 'Pick a month.';
  end if;

  v_from := date_trunc('month', p_month)::date;
  v_to := (v_from + interval '1 month')::date;
  v_end := least(v_to, v_today + 1);
  v_days := greatest(v_end - v_from, 0);
  -- Same span of days in the previous month / same month last year (clipped to that month's end).
  v_prev_from := (v_from - interval '1 month')::date;
  v_prev_to := least(v_prev_from + v_days, v_from);
  v_ly_from := (v_from - interval '1 year')::date;
  v_ly_to := least(v_ly_from + v_days, (v_ly_from + interval '1 month')::date);

  with orders as (
    select o."OrderID" as order_id,
           coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
           coalesce(o."ReceivedAtShop", false) as walkin,
           case when o."ReceivedAtShop" is true then o."Date"
                else coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") end as day,
           coalesce(o."MoneyToCollect", 0) as total,
           coalesce(o."Discount", 0) as discount,
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
      and ((o."Date" >= v_from and o."Date" < v_to)
           or (o."ConfirmedAtUtc" >= (v_from::timestamp at time zone 'Asia/Manila')
               and o."ConfirmedAtUtc" < (v_to::timestamp at time zone 'Asia/Manila')))
      and (
        (o."ReceivedAtShop" is true and o."Date" >= v_from and o."Date" < v_to)
        or (o."ReceivedAtShop" is not true
            and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") >= v_from
            and coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") < v_to)
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
    group by pd.wh, pd.walkin, 3
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
           coalesce(br."Revenue", l."GrossAmount", 0) as amount
    from orders x
    join public."OnlineOrderLines" l on l."OrderID" = x.order_id
    left join public."OnlineOrderLineBundleRevenue" br on br."OrderID" = l."OrderID" and br."LineID" = l."LineID"
    left join public."Variants" v on v."VariationId" = l."VariationId"
    left join public."Items" i on i."Code" = coalesce(nullif(trim(v."MainItemCode"), ''), nullif(trim(v."ItemCode"), ''), nullif(trim(l."ItemCode"), ''))
  ),
  exp as (
    select e.day, coalesce(nullif(trim(e.wh), ''), '(No warehouse)') as wh, e.category, e.amount
    from (
      select h."Date" as day, h."Warehouse" as wh, h."ExpenseCategory"::text as category, coalesce(h."NetAmount", 0) as amount
      from public."ExpenseEntryHeader" h where h."Date" >= v_from and h."Date" < v_to
      union all
      select j."EntryDate", j."Warehouse", j."ExpenseCategory"::text, coalesce(j."Amount", 0)
      from public."ExpenseJournalEntries" j where j."EntryDate" >= v_from and j."EntryDate" < v_to
        and not exists (select 1 from public."BusinessBillPayments" bp where bp."ExpenseJournalEntryID" = j."EntryID")
    ) e
  )
  select jsonb_build_object(
    'month', v_from,
    'month_end', v_to - 1,
    'through', v_end - 1,
    -- Per branch, for the same span of days: previous month and the same month last year.
    'compare', jsonb_build_object(
      'prev_from', v_prev_from, 'prev_to', v_prev_to - 1,
      'ly_from', v_ly_from, 'ly_to', v_ly_to - 1,
      'prev', coalesce((select jsonb_agg(to_jsonb(t)) from public._sales_totals_by_branch(v_prev_from, v_prev_to) t), '[]'::jsonb),
      'last_year', coalesce((select jsonb_agg(to_jsonb(t)) from public._sales_totals_by_branch(v_ly_from, v_ly_to) t), '[]'::jsonb)
    ),
    -- Day-by-day sales per branch / type (advance_copy = the part that is really an advance order).
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('date', d.day, 'warehouse', d.wh, 'is_walkin', d.walkin,
                                          'amount', d.amount, 'count', d.cnt, 'discount', d.discount,
                                          'advance_copy', d.adv) order by d.day, d.wh)
      from (
        select x.day, x.wh, x.walkin, sum(x.total) as amount, count(*) as cnt, sum(x.discount) as discount,
               coalesce(sum(x.total) filter (where x.advance_copy), 0) as adv
        from orders x group by 1, 2, 3
      ) d), '[]'::jsonb),
    'tenders', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', t.wh, 'is_walkin', t.walkin, 'method', t.method,
                                          'amount', t.amount, 'order_count', t.cnt) order by t.amount desc)
      from tenders t where t.amount <> 0), '[]'::jsonb),
    'staff', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', s.wh, 'is_walkin', s.walkin, 'staff', s.staff,
                                          'amount', s.amount, 'count', s.cnt) order by s.amount desc)
      from (select x.wh, x.walkin, x.staff, sum(x.total) as amount, count(*) as cnt from orders x group by 1, 2, 3) s
    ), '[]'::jsonb),
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
    -- Expenses per day + branch (day-by-day table) and per category + branch.
    'expenses', coalesce((
      select jsonb_agg(jsonb_build_object('date', e.day, 'warehouse', e.wh, 'amount', e.amount, 'count', e.cnt) order by e.day, e.wh)
      from (select day, wh, sum(amount) as amount, count(*) as cnt from exp group by 1, 2) e), '[]'::jsonb),
    'expense_categories', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', e.wh, 'category', e.category, 'amount', e.amount, 'count', e.cnt) order by e.amount desc)
      from (select wh, coalesce(nullif(trim(category), ''), '(No category)') as category, sum(amount) as amount, count(*) as cnt
            from exp group by 1, 2) e), '[]'::jsonb),
    -- POS end-of-day cash counts summed per branch.
    'cash', coalesce((
      select jsonb_agg(jsonb_build_object('warehouse', c.wh, 'counts', c.cnt, 'cash_sales', c.cash_sales,
                                          'short', c.short, 'over', c.over, 'variance', c.variance,
                                          'short_days', c.short_days) order by c.wh)
      from (
        select coalesce(nullif(trim(h."Warehouse"), ''), '(No warehouse)') as wh, count(*) as cnt,
               sum(coalesce(h."CashSales", 0)) as cash_sales,
               sum(least(coalesce(h."Variance", 0), 0)) as short,
               sum(greatest(coalesce(h."Variance", 0), 0)) as over,
               sum(coalesce(h."Variance", 0)) as variance,
               count(*) filter (where coalesce(h."Variance", 0) < 0) as short_days
        from public."TenderDeclarationHeader" h
        where h."DeclDate" >= v_from and h."DeclDate" < v_to
        group by 1
      ) c), '[]'::jsonb),
    -- Advance orders placed in the month (voided left out), per day + branch.
    'advance_placed', coalesce((
      select jsonb_agg(jsonb_build_object('date', a.day, 'warehouse', a.wh, 'count', a.cnt, 'net', a.net,
                                          'downpayment', a.down, 'balance', a.bal) order by a.day, a.wh)
      from (
        select a."Date" as day, coalesce(nullif(trim(a."Warehouse"), ''), '(No warehouse)') as wh, count(*) as cnt,
               sum(coalesce(a."NetAmount", 0)) as net, sum(coalesce(a."Downpayment", 0)) as down,
               sum(greatest(coalesce(a."Balance", 0), 0)) as bal
        from public."AdvanceOrders" a
        where a."Date" >= v_from and a."Date" < v_to and not coalesce(a."IsVoid", false)
        group by 1, 2
      ) a), '[]'::jsonb),
    -- Advance-order money collected in the month, per day + branch + tender (voided NOT filtered, like the daily).
    'advance_collected', coalesce((
      select jsonb_agg(jsonb_build_object('date', c.day, 'warehouse', c.wh, 'tender', c.tender, 'amount', c.amount,
                                          'payment_count', c.cnt) order by c.day, c.amount desc)
      from (
        select p."Date" as day,
               coalesce(nullif(trim(coalesce(a."Warehouse", p."Warehouse")), ''), '(No warehouse)') as wh,
               coalesce(nullif(upper(trim(p."TenderTypeCode")), ''), '(No tender)') as tender,
               sum(coalesce(p."Amount", 0)) as amount, count(*) as cnt
        from public."AdvanceOrderPayments" p
        left join public."AdvanceOrders" a on a."TransactionNo" = p."AdvanceTransactionNo"
        where p."Date" >= v_from and p."Date" < v_to
        group by 1, 2, 3
      ) c), '[]'::jsonb),
    -- Every branch, so the filter lists branches even with no sales this month.
    'warehouses', coalesce((
      select jsonb_agg(n order by n) from (
        select distinct trim(w."Name") as n from public."Warehouses" w where nullif(trim(w."Name"), '') is not null
      ) z), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

grant execute on function public.admin_get_monthly_sales_report(text, text, date) to anon;

notify pgrst, 'reload schema';

-- Check - one result.
select 'report function' as section,
       case when to_regprocedure('public.admin_get_monthly_sales_report(text, text, date)') is not null then 'ready' else 'MISSING' end as value
union all
select 'compare helper',
       case when to_regprocedure('public._sales_totals_by_branch(date, date)') is not null then 'ready' else 'MISSING' end
union all
select 'needs custom aquarium revenue view',
       case when to_regclass('public."OnlineOrderLineBundleRevenue"') is not null then 'ok' else 'RUN supabase_custom_aquarium_part_revenue.sql' end
union all
select 'this month so far (all branches)',
       to_char(coalesce((select sum(online_sales + walkin_sales)
                         from public._sales_totals_by_branch(date_trunc('month', (now() at time zone 'Asia/Manila'))::date,
                                                             (now() at time zone 'Asia/Manila')::date + 1)), 0), 'FM999,999,999,990.00');
