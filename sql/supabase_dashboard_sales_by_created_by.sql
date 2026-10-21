-- Dashboard "Sales by Staff": a Vic card counted by CREATED BY - per "can you show Add vic there but
-- only for created .. i want to see how much Vic has been created". Vic (the Messenger bot) isn't a
-- StaffUsers row and never confirms orders, so admin_get_sales_by_confirmed_by can't show him - this
-- returns the same figures for orders whose "CreatedBy" = p_created_by instead of "ConfirmedBy".
--
-- Same rules as admin_get_sales_by_confirmed_by (supabase_dashboard_sales_by_staff_exclude_inactive.sql)
-- so the cards read the same: Daily = confirmed today (falls back to "Date"), Monthly / Prev. Month by
-- "Date", walk-ins and cancelled orders left out. Exact (lower/trim) name match.
--
-- Needs js/dashboard.js + dashboard.html cache v=vicstat1 and js/onlineOrders.js + online-orders.html
-- v=vicstat1 (the ?createdBy= link). Safe to re-run.

drop function if exists public.admin_get_sales_by_created_by(text, text, text);

create or replace function public.admin_get_sales_by_created_by(
  p_admin_username text,
  p_admin_password text,
  p_created_by text
)
returns table(
  display_name text,
  daily_sales numeric,
  daily_order_count int,
  monthly_sales numeric,
  monthly_order_count int,
  previous_month_sales numeric,
  previous_month_order_count int
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_today date;
  v_month_start date;
  v_month_end date;
  v_prev_month_start date;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_today := (now() at time zone 'Asia/Manila')::date;
  v_month_start := date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month')::date;
  v_prev_month_start := (v_month_start - interval '1 month')::date;

  return query
    select
      trim(p_created_by)::text,
      coalesce(sum(o."MoneyToCollect") filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
      ), 0)::numeric,
      count(*) filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
      )::int,
      coalesce(sum(o."MoneyToCollect") filter (where o."Date" >= v_month_start and o."Date" < v_month_end), 0)::numeric,
      count(*) filter (where o."Date" >= v_month_start and o."Date" < v_month_end)::int,
      coalesce(sum(o."MoneyToCollect") filter (where o."Date" >= v_prev_month_start and o."Date" < v_month_start), 0)::numeric,
      count(*) filter (where o."Date" >= v_prev_month_start and o."Date" < v_month_start)::int
    from public."OnlineOrders" o
    where lower(trim(o."CreatedBy")) = lower(trim(p_created_by))
      and o."ReceivedAtShop" is not true
      and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled');
end;
$$;

grant execute on function public.admin_get_sales_by_created_by(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - Vic's figures right now.
select 'Vic' as created_by,
       count(*) filter (where o."Date" >= date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date) as orders_this_month,
       coalesce(sum(o."MoneyToCollect") filter (where o."Date" >= date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date), 0) as sales_this_month,
       count(*) as orders_all_time
from public."OnlineOrders" o
where lower(trim(o."CreatedBy")) = 'vic'
  and o."ReceivedAtShop" is not true
  and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled');
