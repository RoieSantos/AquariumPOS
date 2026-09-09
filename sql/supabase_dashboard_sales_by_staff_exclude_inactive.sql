-- Per "exclude the member that is already disabled on the user setup" - the Dashboard's
-- "Sales by Staff" section (loadSalesByStaff in js/dashboard.js) lists one card per staff
-- member flagged SalesUser = true in StaffUsers, but admin_get_sales_by_confirmed_by never
-- checked StaffUsers."IsActive" - a Sales User disabled in User Setup (the "Active" toggle,
-- see userSetup.js) still showed up with a card here.
--
-- This just redefines admin_get_sales_by_confirmed_by() (see supabase_orders_sync_tables.sql /
-- supabase_dashboard_daily_sales_include_status.sql) to also require "IsActive" is true - run
-- this once in the Supabase SQL editor to apply it.
drop function if exists public.admin_get_sales_by_confirmed_by(text, text);

create or replace function public.admin_get_sales_by_confirmed_by(p_admin_username text, p_admin_password text)
returns table(
  display_name text,
  daily_sales numeric,
  daily_order_count int,
  monthly_sales numeric,
  monthly_order_count int,
  previous_month_sales numeric,
  previous_month_order_count int,
  monthly_sales_target numeric
)
language plpgsql
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
      su."DisplayName"::text,
      coalesce(sum(o."MoneyToCollect") filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
      ), 0)::numeric as daily_sales,
      count(*) filter (
        where coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
      )::int as daily_order_count,
      coalesce(sum(o."MoneyToCollect") filter (where o."Date" >= v_month_start and o."Date" < v_month_end), 0)::numeric as monthly_sales,
      count(*) filter (where o."Date" >= v_month_start and o."Date" < v_month_end)::int as monthly_order_count,
      coalesce(sum(o."MoneyToCollect") filter (where o."Date" >= v_prev_month_start and o."Date" < v_month_start), 0)::numeric as previous_month_sales,
      count(*) filter (where o."Date" >= v_prev_month_start and o."Date" < v_month_start)::int as previous_month_order_count,
      coalesce(su."MonthlySalesTarget", 0)::numeric as monthly_sales_target
    from public."StaffUsers" su
    left join public."OnlineOrders" o
      on lower(trim(o."ConfirmedBy")) = lower(trim(su."DisplayName"))
      and o."ReceivedAtShop" is not true
      and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
    where su."SalesUser" is true
      and su."IsActive" is true
      and su."DisplayName" is not null and trim(su."DisplayName") <> ''
    group by su."DisplayName", su."MonthlySalesTarget"
    order by su."DisplayName";
end;
$$;

grant execute on function public.admin_get_sales_by_confirmed_by(text, text) to anon;
