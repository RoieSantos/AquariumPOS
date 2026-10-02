-- Dashboard Monthly section: replaces the all-time "Amount to Receive" card with this month's
-- "Amount Paid" and "Amount to Receive" (docs/dashboard.html, docs/js/dashboard.js
-- loadFinancialSummary). Per "instead of amount to receive.. compute the amount paid for this
-- month and amount about to receive for this month".
--
-- Adds month_amount_paid / month_paid_order_count / month_amount_to_receive /
-- month_to_receive_order_count to admin_get_online_order_financial_summary. Return shape changes,
-- so it is dropped and recreated (Postgres 42P13). supabase_orders_sync_tables.sql carries the
-- same change, so re-running that file won't undo this.

drop function if exists public.admin_get_online_order_financial_summary(text, text, text);

create or replace function public.admin_get_online_order_financial_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null)
returns table(
  amount_to_receive numeric, month_sales numeric, month_order_count int, month_sales_target numeric,
  walkin_sales_month numeric, walkin_order_count int,
  today_online_sales numeric, today_online_order_count int,
  today_walkin_sales numeric, today_walkin_order_count int,
  previous_month_walkin_sales numeric, previous_month_walkin_order_count int,
  month_amount_paid numeric, month_paid_order_count int,
  month_amount_to_receive numeric, month_to_receive_order_count int
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
      )::int as previous_month_walkin_order_count,
      coalesce(sum(o."AmountPaid") filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as month_amount_paid,
      count(*) filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and coalesce(o."AmountPaid", 0) > 0
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as month_paid_order_count,
      coalesce(sum(o."Balance") filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."Balance" > 0
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      ), 0)::numeric as month_amount_to_receive,
      count(*) filter (
        where o."Date" >= v_month_start and o."Date" < v_month_end
          and o."Balance" > 0
          and o."ReceivedAtShop" is not true
          and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
      )::int as month_to_receive_order_count
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name;
end;
$$;

grant execute on function public.admin_get_online_order_financial_summary(text, text, text) to anon;
