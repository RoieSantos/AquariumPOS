-- Follow-up to supabase_dashboard_daily_sales_include_status.sql: that migration switched
-- admin_get_sales_by_confirmed_by's daily_sales/daily_order_count to key off "ConfirmedAtUtc"
-- (the real Pancake status=1 timestamp) instead of "Date" (order placed date), so a Sales User's
-- "Daily" figure now reflects orders they actually confirmed today, regardless of when the order
-- was originally placed or what fulfillment status it's since reached.
--
-- Per "one I clicked by daily sales I want to be able to see all the orders linked to it" -
-- clicking that Daily figure links to online-orders.html?confirmedBy=...&period=today, which was
-- still only matching orders whose "Date" was today, so the drill-down list didn't match what the
-- figure counted.
--
-- This redefines admin_list_online_orders() (see supabase_orders_sync_tables.sql) so its
-- p_period = 'today' filter uses the exact same ConfirmedAtUtc-based rule, but ONLY when
-- p_confirmed_by is also set - i.e. only the per-staff Daily drill-down is widened. The general
-- Today's Online Sales / Today's Walk-In Sales dashboard cards (which link here with
-- period=today but no confirmedBy) keep the plain "Date" = today behavior their own totals are
-- still computed with, so those figures and their drill-down lists still always match each other.
--
-- Run this once in the Supabase SQL editor, after supabase_dashboard_daily_sales_include_status.sql.
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text);

create or replace function public.admin_list_online_orders(
  p_admin_username text, p_admin_password text,
  p_search text default null, p_status text default null, p_order_id text default null,
  p_period text default null, p_walkin_only boolean default false,
  p_page int default 1, p_page_size int default 50,
  p_confirmed_by text default null
)
returns table(
  order_id text,
  order_date date,
  order_time text,
  status text,
  customer_name text,
  location_id text,
  warehouse_name text,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
  balance numeric,
  for_delivery boolean,
  shipping_address text,
  estimated_delivery_date date,
  last_updated_at timestamptz,
  synced_at_utc timestamptz,
  glass_thickness text,
  created_by text,
  confirmed_by text,
  note_print text,
  delivery_fee numeric,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
  v_today date;
  v_prev_month_start date;
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_period in ('month', 'today', 'prevmonth') then
    v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
    v_month_end := (v_month_start + interval '1 month')::date;
    v_today := (now() at time zone 'Asia/Manila')::date;
    v_prev_month_start := (v_month_start - interval '1 month')::date;
  end if;

  return query
    select o."OrderID"::text, o."Date", o."Time"::text, o."Status"::text, o."CustomerName"::text, o."LocationID"::text, w."Name"::text,
           o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance", o."ForDelivery", o."ShippingAddress"::text,
           o."EstimatedDeliveryDate", o."Last_Updated_At", o."SyncedAtUtc", o."GlassThickness"::text,
           o."CreatedBy"::text, o."ConfirmedBy"::text, o."NotePrint"::text, o."DeliveryFee",
           count(*) over()
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where (case when p_walkin_only then o."ReceivedAtShop" is true else o."ReceivedAtShop" is not true end)
      and (p_period is distinct from 'month' or (o."Date" >= v_month_start and o."Date" < v_month_end))
      and (
        p_period is distinct from 'today'
        or (
          case
            when p_confirmed_by is not null and trim(p_confirmed_by) <> ''
              then coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
            else o."Date" = v_today
          end
        )
      )
      and (p_period is distinct from 'prevmonth' or (o."Date" >= v_prev_month_start and o."Date" < v_month_start))
      and (p_confirmed_by is null or trim(p_confirmed_by) = '' or lower(trim(o."ConfirmedBy")) = lower(trim(p_confirmed_by)))
      and (
        (p_order_id is not null and trim(p_order_id) <> '' and o."OrderID" = p_order_id)
        or (
          (p_order_id is null or trim(p_order_id) = '')
          and (p_search is null or trim(p_search) = '' or o."OrderID" ilike '%' || p_search || '%' or o."CustomerName" ilike '%' || p_search || '%')
          and (p_status is null or trim(p_status) = '' or o."Status" ilike '%' || p_status || '%')
        )
      )
    order by o."Last_Updated_At" desc nulls last, o."Date" desc nulls last
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text) to anon;
