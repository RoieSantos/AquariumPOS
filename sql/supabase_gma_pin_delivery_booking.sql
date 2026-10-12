-- GMA Conversations: book a delivery from a customer's pinned location, with its delivery fee - per
-- "once they send this [📍 My delivery location].. link this to the delivery calendar.. book to the
-- calendar for a specific date and order id" and "show the price too base on the customer's pin.. once
-- schedule delivery with this pin it will auto populate the delivery fee on that order and calendar".
--
-- The "Schedule delivery" box under a 📍 message shows the fee to that pin (delivery-fee-from-pin Edge
-- Function - the bot's own official formula) and opens the Delivery Calendar in booking mode; staff pick
-- the order + date and Book -> admin_book_delivery_from_pin:
--   * the stop: the order's upcoming (not done) stop is MOVED to the new date if it has one - never a
--     second stop for the same order; otherwise a new one is created exactly like the Delivery page
--     (admin_create_delivery_stop - same truck / route / date rules);
--   * the pin becomes the stop's map location (GeocodeStatus 'ok'), the pinned address its delivery
--     address, the landmark its notes, and the fee its delivery fee (ManualDeliveryFee) on the calendar;
--   * the fee also goes on the ORDER: a draft GMA order (not pushed anywhere) -> AutomatedOrders fee +
--     total, plus the pinned address; a GMA order already confirmed into Online Orders ->
--     admin_set_portal_order_delivery_fee (fee, amount to collect, balance). A Pancake order's fee is left
--     alone (it lives in Pancake) and fee_note says so.
--
-- Run AFTER supabase_gma_location_pin.sql. Safe to re-run.
-- Needs the delivery-fee-from-pin Edge Function deployed and js/gmaConversations.js ?v=pinfee1.

drop function if exists public.admin_book_delivery_from_pin(text, text, text, date, numeric, numeric, text, text);

create or replace function public.admin_book_delivery_from_pin(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,            -- AutomatedOrders.OrderNo (GMA order)
  p_delivery_date date,
  p_latitude numeric,
  p_longitude numeric,
  p_address text default null,
  p_notes text default null,
  p_delivery_fee numeric default null   -- null = don't touch any fee
)
returns table(stop_id uuid, moved boolean, fee_note text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_stop_id uuid;
  v_moved boolean := false;
  v_address text := nullif(trim(coalesce(p_address, '')), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_fee numeric(18, 2) := round(p_delivery_fee, 2);
  v_ao public."AutomatedOrders"%rowtype;
  v_synced_id text;
  v_fee_note text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_latitude is null or p_longitude is null then
    raise exception 'The pinned location has no coordinates.';
  end if;
  if v_fee is not null and v_fee < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;

  select * into v_ao from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  select o."OrderID" into v_synced_id
  from public."OnlineOrders" o where o."OrderID" = nullif(trim(v_ao."PancakeReceiptNo"), '');

  -- 1. The stop: move this order's upcoming, not-yet-done stop if there is one, else create it.
  select s."StopID" into v_stop_id
  from public."DeliveryStops" s
  where (s."AutomatedOrderNo" = p_order_no or (v_synced_id is not null and s."OrderID" = v_synced_id))
    and s."DeliveryDate" >= (now() at time zone 'Asia/Manila')::date
    and not exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID")
  order by s."DeliveryDate"
  limit 1;

  if v_stop_id is not null then
    if (select "DeliveryDate" from public."DeliveryStops" where "StopID" = v_stop_id) <> p_delivery_date then
      perform public.admin_move_delivery_stop(p_admin_username, p_admin_password, v_stop_id, p_delivery_date);
    end if;
    v_moved := true;
    if v_notes is not null then
      update public."DeliveryStops" set "Notes" = 'Landmark: ' || v_notes where "StopID" = v_stop_id;
    end if;
  else
    v_stop_id := public.admin_create_delivery_stop(
      p_admin_username, p_admin_password, p_order_no, p_delivery_date, null,
      case when v_notes is not null then 'Landmark: ' || v_notes end, 'automated');
  end if;

  -- 2. The pin (+ fee) on the stop - what the Delivery page / calendar plot and show.
  update public."DeliveryStops"
     set "Latitude" = p_latitude,
         "Longitude" = p_longitude,
         "GeocodeStatus" = 'ok',
         "GeocodedAddress" = coalesce(v_address, round(p_latitude, 6) || ',' || round(p_longitude, 6)),
         "GeocodedAtUtc" = now(),
         "ManualAddress" = coalesce(v_address, "ManualAddress"),
         "ManualDeliveryFee" = coalesce(v_fee, "ManualDeliveryFee")
   where "StopID" = v_stop_id;

  -- 3. The fee (+ pinned address) on the order.
  if v_fee is not null then
    if v_ao."PancakeSyncStatus" = 'Portal' and v_synced_id is not null then
      -- Confirmed into Online Orders: same function as Online Orders' editable Delivery Fee.
      begin
        perform public.admin_set_portal_order_delivery_fee(p_admin_username, p_admin_password, v_synced_id, v_fee);
        v_fee_note := 'Delivery fee set on Online Order ' || v_synced_id || '.';
      exception when others then
        v_fee_note := 'Booked, but the order''s delivery fee was not changed: ' || sqlerrm;
      end;
    elsif coalesce(v_ao."PancakeSyncStatus", 'Not Pushed') = 'Not Pushed' then
      if v_ao."Status" in ('Completed', 'Cancelled') then
        v_fee_note := 'Booked, but order ' || p_order_no || ' is ' || v_ao."Status" || ' - its delivery fee was not changed.';
      else
        update public."AutomatedOrders"
           set "DeliveryFee" = v_fee,
               "EstimatedTotal" = coalesce("EstimatedTotal", 0) - coalesce("DeliveryFee", 0) + v_fee,
               "FulfillmentType" = 'Delivery',
               "DeliveryAddress" = coalesce(v_address, "DeliveryAddress"),
               "UpdatedAtUtc" = now()
         where "OrderNo" = p_order_no;
        v_fee_note := 'Delivery fee set on order ' || p_order_no || '.';
      end if;
    else
      v_fee_note := 'Booked, but order ' || p_order_no || ' is a Pancake order - set its delivery fee in Pancake.';
    end if;
  end if;

  return query select v_stop_id, v_moved, v_fee_note;
end;
$$;

grant execute on function public.admin_book_delivery_from_pin(text, text, text, date, numeric, numeric, text, text, numeric) to anon;

notify pgrst, 'reload schema';
