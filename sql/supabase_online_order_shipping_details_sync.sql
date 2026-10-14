-- Online Orders card <-> Delivery calendar: keep the Shipping Address, Shipping Contact Number and
-- Delivery Fee of a portal (AO-) order in step both ways - per "can we apply that to the Address too?
-- add a new field Shipping address, Shipping contact number".
--
-- 1. admin_get_order_shipping_details - the order's ShippingAddress / ShippingPhone for the card's new
--    Shipping Address / Shipping Contact Number fields (ShippingPhone isn't in admin_list_online_orders).
-- 2. admin_set_portal_order_shipping_details - edit them on an open portal delivery order (same rules
--    as admin_set_portal_order_delivery_fee: Source = 'Portal', ForDelivery, not Shipped / Delivered /
--    Completed / Cancelled / Returned). Keeps the source AutomatedOrders row in step, and copies the new
--    values onto the order's Delivery stops (ManualAddress / ManualContactNumber) so the calendar,
--    driver view, receipt and invoice show them. A stop whose address changed is marked
--    GeocodeStatus = 'stale' - js/delivery.js re-plots it on the map the next time that day is opened.
--    p_from_stop_id = the stop being edited on the calendar (already saved with its own pin) - skipped.
-- 3. admin_set_portal_order_delivery_fee (supabase_online_order_portal_delivery_fee.sql) re-created:
--    + clears the order's stops' ManualDeliveryFee, so a fee changed on the card shows on the calendar
--    too (the stop falls back to the order's fee) instead of an older calendar-typed fee winning.
--
-- Pancake orders are refused (the next sync would overwrite ShippingAddress / ShippingPhone) - change
-- those in Pancake; the calendar still keeps its own per-stop override for them.
--
-- Run AFTER supabase_delivery_stop_manual_fee.sql. Replaces supabase_online_order_portal_delivery_fee.sql
-- (no need to run that one first, and do NOT re-run it after this - it would undo step 3). Safe to re-run. Needs js/onlineOrders.js ?v=shipdetails1 and js/delivery.js ?v=shipdetails1.

-- ---------------------------------------------------------------------------
-- 1. Read

drop function if exists public.admin_get_order_shipping_details(text, text, text);

create or replace function public.admin_get_order_shipping_details(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(shipping_address text, shipping_phone text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."ShippingAddress"::text, o."ShippingPhone"::text
    from public."OnlineOrders" o
    where o."OrderID" = trim(coalesce(p_order_id, ''));
end;
$$;

grant execute on function public.admin_get_order_shipping_details(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Write (portal orders)

drop function if exists public.admin_set_portal_order_shipping_details(text, text, text, text, text, uuid);

create or replace function public.admin_set_portal_order_shipping_details(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_shipping_address text,
  p_shipping_phone text,
  p_from_stop_id uuid default null
)
returns table(shipping_address text, shipping_phone text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_order public."OnlineOrders"%rowtype;
  v_status text;
  v_address text := left(nullif(trim(coalesce(p_shipping_address, '')), ''), 1000);
  v_phone text := left(nullif(trim(coalesce(p_shipping_phone, '')), ''), 50);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  begin
    select * into v_order from public."OnlineOrders" where "OrderID" = v_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (another update is still running on it). Wait a minute, refresh and try again.', v_order_id;
  end;
  if not found then
    raise exception 'Order % not found.', v_order_id;
  end if;
  if coalesce(v_order."Source", '') <> 'Portal' then
    raise exception 'Order % is a Pancake order - change its shipping address / contact number in Pancake instead.', v_order_id;
  end if;
  if not coalesce(v_order."ForDelivery", false) then
    raise exception 'Order % is a pickup order - it has no shipping address.', v_order_id;
  end if;
  v_status := lower(trim(coalesce(v_order."Status", '')));
  if v_status in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning') then
    raise exception 'Order % is %, its shipping details can no longer be changed.', v_order_id, v_order."Status";
  end if;

  update public."OnlineOrders"
  set "ShippingAddress" = v_address,
      "ShippingPhone" = v_phone,
      "Last_Updated_At" = now()
  where "OrderID" = v_order_id;

  -- CustomerPhone is NOT NULL there - a blanked phone keeps the old one on the source row.
  update public."AutomatedOrders"
  set "DeliveryAddress" = left(v_address, 500),
      "CustomerPhone" = coalesce(v_phone, "CustomerPhone"),
      "UpdatedAtUtc" = now()
  where "PancakeReceiptNo" = v_order_id and "PancakeSyncStatus" = 'Portal';

  update public."DeliveryStops"
  set "ManualAddress" = v_address,
      "ManualContactNumber" = v_phone,
      "GeocodeStatus" = case
        when v_address is not null and v_address is distinct from "GeocodedAddress" then 'stale'
        else "GeocodeStatus"
      end
  where "OrderID" = v_order_id
    and (p_from_stop_id is null or "StopID" <> p_from_stop_id);

  return query
    select o."ShippingAddress"::text, o."ShippingPhone"::text
    from public."OnlineOrders" o where o."OrderID" = v_order_id;
end;
$$;

grant execute on function public.admin_set_portal_order_shipping_details(text, text, text, text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- 3. Delivery fee (card) - same as supabase_online_order_portal_delivery_fee.sql + clears the stops'
--    ManualDeliveryFee so the calendar follows the order's new fee.

drop function if exists public.admin_set_portal_order_delivery_fee(text, text, text, numeric);

create or replace function public.admin_set_portal_order_delivery_fee(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_delivery_fee numeric
)
returns table(delivery_fee numeric, money_to_collect numeric, balance numeric)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_order public."OnlineOrders"%rowtype;
  v_status text;
  v_old_fee numeric(18, 2);
  v_new_fee numeric(18, 2) := round(coalesce(p_delivery_fee, 0), 2);
  v_delta numeric(18, 2);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_new_fee < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;

  begin
    select * into v_order from public."OnlineOrders" where "OrderID" = v_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (another update is still running on it). Wait a minute, refresh and try again.', v_order_id;
  end;
  if not found then
    raise exception 'Order % not found.', v_order_id;
  end if;
  if coalesce(v_order."Source", '') <> 'Portal' then
    raise exception 'Order % is a Pancake order - set its delivery fee in Pancake instead.', v_order_id;
  end if;
  if not coalesce(v_order."ForDelivery", false) then
    raise exception 'Order % is a pickup order - it has no delivery fee.', v_order_id;
  end if;
  v_status := lower(trim(coalesce(v_order."Status", '')));
  if v_status in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning') then
    raise exception 'Order % is %, its delivery fee can no longer be changed.', v_order_id, v_order."Status";
  end if;

  v_old_fee := coalesce(v_order."DeliveryFee", 0);
  v_delta := v_new_fee - v_old_fee;

  update public."OnlineOrders"
  set "DeliveryFee" = nullif(v_new_fee, 0),
      "MoneyToCollect" = coalesce("MoneyToCollect", 0) + v_delta,
      "Balance" = coalesce("Balance", 0) + v_delta,
      "Last_Updated_At" = now()
  where "OrderID" = v_order_id;

  update public."AutomatedOrders"
  set "DeliveryFee" = v_new_fee,
      "EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta,
      "UpdatedAtUtc" = now()
  where "PancakeReceiptNo" = v_order_id and "PancakeSyncStatus" = 'Portal';

  -- This file: the calendar follows the order's fee from now on.
  update public."DeliveryStops"
  set "ManualDeliveryFee" = null
  where "OrderID" = v_order_id and "ManualDeliveryFee" is not null;

  return query
    select o."DeliveryFee", o."MoneyToCollect", o."Balance"
    from public."OnlineOrders" o where o."OrderID" = v_order_id;
end;
$$;

grant execute on function public.admin_set_portal_order_delivery_fee(text, text, text, numeric) to anon;

notify pgrst, 'reload schema';
