-- Monthly Sales Report > Year view - per "can we build like per warehouse per month on the whole year so i can
-- compare and see how is it growing or decreasing".
--
-- One year as months x branches, plus the year before so the page can show growth vs the previous month
-- (January vs last December) and vs the same month last year. Same rules as the Daily / Monthly Sales Report:
--   * online  - ReceivedAtShop not true, ConfirmedAtUtc's Manila date (falls back to "Date"), not cancelled
--   * walk-in - ReceivedAtShop true, "Date", not cancelled; sales = MoneyToCollect
--   * expenses = POS expenses + Expense Journal, Bills & Dues payments left out
--   * advance collected = AdvanceOrderPayments (kept apart from sales, like the other reports)
--
-- The current month is only partly over, so 'partial' gives the same days of the previous month and of the
-- same month last year (Nov 1-17 vs Oct 1-17 / Nov 1-17 last year) for a fair sales growth %.
--
-- Super users only (is_admin_authorized). Run AFTER supabase_monthly_sales_report.sql (uses
-- _sales_totals_by_branch). Safe to re-run. Needs js/monthlySalesReport.js ?v=yearsales1. Ends with ONE result.

drop function if exists public.admin_get_yearly_sales_report(text, text, int);

create or replace function public.admin_get_yearly_sales_report(
  p_admin_username text,
  p_admin_password text,
  p_year int
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_from date;   -- Jan 1 of the year BEFORE p_year (for the growth compare)
  v_to date;     -- Jan 1 after p_year (exclusive)
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_cur date := date_trunc('month', (now() at time zone 'Asia/Manila'))::date;
  v_days int;
  v_result jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_year is null or p_year < 2000 or p_year > 2100 then
    raise exception 'Pick a year.';
  end if;

  v_from := make_date(p_year - 1, 1, 1);
  v_to := make_date(p_year + 1, 1, 1);
  v_days := v_today - v_cur + 1;

  with orders as (
    select coalesce(nullif(trim(w."Name"), ''), '(No warehouse)') as wh,
           coalesce(o."ReceivedAtShop", false) as walkin,
           case when o."ReceivedAtShop" is true then o."Date"
                else coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") end as day,
           coalesce(o."MoneyToCollect", 0) as total
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      and ((o."Date" >= v_from and o."Date" < v_to)
           or (o."ConfirmedAtUtc" >= (v_from::timestamp at time zone 'Asia/Manila')
               and o."ConfirmedAtUtc" < (v_to::timestamp at time zone 'Asia/Manila')))
  ),
  inrange as (
    select * from orders where day >= v_from and day < v_to
  ),
  exp as (
    select h."Date" as day, h."Warehouse" as wh, coalesce(h."NetAmount", 0) as amount
    from public."ExpenseEntryHeader" h where h."Date" >= v_from and h."Date" < v_to
    union all
    select j."EntryDate", j."Warehouse", coalesce(j."Amount", 0)
    from public."ExpenseJournalEntries" j where j."EntryDate" >= v_from and j."EntryDate" < v_to
      and not exists (select 1 from public."BusinessBillPayments" bp where bp."ExpenseJournalEntryID" = j."EntryID")
  )
  select jsonb_build_object(
    'year', p_year,
    'today', v_today,
    'current_month', v_cur,
    -- Sales per month + branch, for p_year and the year before.
    'sales', coalesce((
      select jsonb_agg(jsonb_build_object('month', s.m, 'warehouse', s.wh,
                                          'online', s.online, 'online_count', s.online_count,
                                          'walkin', s.walkin, 'walkin_count', s.walkin_count) order by s.m, s.wh)
      from (
        select date_trunc('month', x.day)::date as m, x.wh,
               coalesce(sum(x.total) filter (where not x.walkin), 0) as online,
               count(*) filter (where not x.walkin) as online_count,
               coalesce(sum(x.total) filter (where x.walkin), 0) as walkin,
               count(*) filter (where x.walkin) as walkin_count
        from inrange x group by 1, 2
      ) s), '[]'::jsonb),
    'expenses', coalesce((
      select jsonb_agg(jsonb_build_object('month', e.m, 'warehouse', e.wh, 'amount', e.amount) order by e.m, e.wh)
      from (
        select date_trunc('month', day)::date as m, coalesce(nullif(trim(wh), ''), '(No warehouse)') as wh, sum(amount) as amount
        from exp group by 1, 2
      ) e), '[]'::jsonb),
    'advance_collected', coalesce((
      select jsonb_agg(jsonb_build_object('month', c.m, 'warehouse', c.wh, 'amount', c.amount) order by c.m, c.wh)
      from (
        select date_trunc('month', p."Date")::date as m,
               coalesce(nullif(trim(coalesce(a."Warehouse", p."Warehouse")), ''), '(No warehouse)') as wh,
               sum(coalesce(p."Amount", 0)) as amount
        from public."AdvanceOrderPayments" p
        left join public."AdvanceOrders" a on a."TransactionNo" = p."AdvanceTransactionNo"
        where p."Date" >= v_from and p."Date" < v_to
        group by 1, 2
      ) c), '[]'::jsonb),
    -- The running month, compared on the same days (sales only).
    'partial', case when v_cur >= make_date(p_year, 1, 1) and v_cur < v_to then jsonb_build_object(
        'month', v_cur, 'days', v_days,
        'prev', coalesce((select jsonb_agg(to_jsonb(t)) from public._sales_totals_by_branch(
                  (v_cur - interval '1 month')::date, least((v_cur - interval '1 month')::date + v_days, v_cur)) t), '[]'::jsonb),
        'last_year', coalesce((select jsonb_agg(to_jsonb(t)) from public._sales_totals_by_branch(
                  (v_cur - interval '1 year')::date,
                  least((v_cur - interval '1 year')::date + v_days, ((v_cur - interval '1 year') + interval '1 month')::date)) t), '[]'::jsonb)
      ) end,
    -- First year with any sale, for the year picker.
    'first_year', (select extract(year from min(o."Date"))::int from public."OnlineOrders" o)
  )
  into v_result;

  return v_result;
end;
$$;

grant execute on function public.admin_get_yearly_sales_report(text, text, int) to anon;

notify pgrst, 'reload schema';

-- Check - one result.
select 'year report function' as section,
       case when to_regprocedure('public.admin_get_yearly_sales_report(text, text, int)') is not null then 'ready' else 'MISSING' end as value
union all
select 'needs monthly report SQL first',
       case when to_regprocedure('public._sales_totals_by_branch(date, date)') is not null then 'ok' else 'RUN supabase_monthly_sales_report.sql' end;
