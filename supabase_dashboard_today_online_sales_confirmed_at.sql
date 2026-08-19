-- Per "so in the daily report of sales.. Today's online sales can we do the same thing" -
-- extends the ConfirmedAtUtc-based "today" fix (see supabase_dashboard_daily_sales_include_status.sql
-- / supabase_dashboard_daily_sales_drilldown_status.sql, applied to the per-staff Daily figure)
-- to the super-user Dashboard's "Today's Online Sales" card too.
--
-- today_online_sales/today_online_order_count now key off "ConfirmedAtUtc" (the real Pancake
-- status=1 timestamp), falling back to "Date" only when it's still null, instead of plain "Date"
-- (when the order was PLACED, not necessarily confirmed) - same reasoning as
-- admin_get_sales_by_confirmed_by's daily_sales. today_walkin_sales is deliberately left alone -
-- walk-in orders are received/paid in-store immediately, so "Date" already reflects the sale;
-- there's no separate "confirmed later" step to account for.
--
-- This redefines admin_get_online_order_financial_summary() (see supabase_orders_sync_tables.sql) -
-- run this once in the Supabase SQL editor. Also run supabase_dashboard_today_online_sales_drilldown.sql
-- so clicking through the card still matches what it counted.
drop function if exists public.admin_get_online_order_financial_summary(text, text, text);

create or replace function public.admin_get_online_order_financial_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null)
returns table(
  amount_to_receive numeric, month_sales numeric, month_order_count int, month_sales_target numeric,
  walkin_sales_month numeric, walkin_order_count int,
  today_online_sales numeric, today_online_order_count int,
  today_walkin_sales numeric, today_walkin_order_count int,
  previous_month_walkin_sales numeric, previous_month_walkin_order_count int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
  v_days_in_month int;
  v_today date;
  v_prev_month_start date;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
  v_month_end := (v_month_start + interval '1 month')::date;
  v_days_in_month := v_month_end - v_month_start;
  v_today := (now() at time zone 'Asia/Manila')::date;
  v_prev_month_start := (v_month_start - interval '1 month')::date;

  return query
    select
      coalesce(sum(o."Balance") filter (
        where o."Balance" > 0
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as amount_to_receive,
      coalesce(sum(o."MoneyToCollect") filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as month_sales,
      count(*) filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as month_order_count,
      (28000 * v_days_in_month)::numeric as month_sales_target,
      coalesce(sum(o."MoneyToCollect") filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as walkin_sales_month,
      count(*) filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as walkin_order_count,
      coalesce(sum(o."MoneyToCollect") filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as today_online_sales,
      count(*) filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as today_online_order_count,
      coalesce(sum(o."MoneyToCollect") filter (
        where o."Date" = v_today
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as today_walkin_sales,
      count(*) filter (
        where o."Date" = v_today
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as today_walkin_order_count,
      coalesce(sum(o."MoneyToCollect") filter (
        where o."Date" >= v_prev_month_start and o."Date" < v_month_start
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as previous_month_walkin_sales,
      count(*) filter (
        where o."Date" >= v_prev_month_start and o."Date" < v_month_start
          and o."ReceivedAtShop" is true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as previous_month_walkin_order_count
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name;
end;
$$;

grant execute on function public.admin_get_online_order_financial_summary(text, text, text) to anon;
