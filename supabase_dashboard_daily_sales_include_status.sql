-- Per "under the sales user Daily can you add printed/toship/shipped status as long as its
-- today's date it will fall on the Daily sales", refined by a follow-up: "can we grab the
-- confirmation date from pancake and flow it to our supabase (portal)? I think its the time when
-- the order has been changed status = 1 (confirmed)".
--
-- The Dashboard's "Sales by Staff" section shows a "Daily" figure per Sales User
-- (staffStatLinkHtml(..., 'today', 'Daily', ...) in js/dashboard.js), sourced from this RPC's
-- daily_sales/daily_order_count. It previously only counted orders whose "Date" (Pancake's
-- inserted_at/created_at - when the order was PLACED) was today. But "Date" isn't when a Sales
-- User actually confirmed the order - an order can be placed on one day and sit unconfirmed for
-- days before a rep confirms (and later prints/ships) it, so gating on "Date" both missed
-- same-day confirmations of older orders and wasn't really measuring the sales action at all.
--
-- "ConfirmedAtUtc" is the real status=1 ("order confirmed") timestamp, pulled straight from
-- Pancake's own status_history via pancake_extract_created_confirmed_by() (already flowing into
-- public."OnlineOrders" - see supabase_pancake_manual_sync.sql / supabase_orders_sync_tables.sql
-- / supabase_order_confirmation_timing_rpc.sql, which already uses this same column for the Order
-- Confirmation Timing dashboard). Its Asia/Manila calendar date is the correct "did this rep
-- confirm this order today" signal - and since it doesn't change when the order later moves to
-- Printed/To Ship/Shipped, those orders stay correctly attributed to the day they were actually
-- confirmed. Falls back to "Date" only when ConfirmedAtUtc is still null (older orders synced
-- before that column existed, or not yet backfilled - see admin_backfill_order_confirmed_at),
-- so nothing silently drops out of Daily while the backfill is catching up.
--
-- This just redefines admin_get_sales_by_confirmed_by() (see supabase_orders_sync_tables.sql) -
-- run this once in the Supabase SQL editor to apply it.
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
      and su."DisplayName" is not null and trim(su."DisplayName") <> ''
    group by su."DisplayName", su."MonthlySalesTarget"
    order by su."DisplayName";
end;
$$;

grant execute on function public.admin_get_sales_by_confirmed_by(text, text) to anon;
