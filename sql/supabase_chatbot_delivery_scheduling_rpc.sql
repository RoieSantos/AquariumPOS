-- Lets a customer self-schedule their own Online Order's delivery date through the AI Messenger
-- chatbot (supabase/functions/facebook-messenger-webhook), ONLY for orders the store delivers
-- itself (own truck) - per direct request. There is no data field anywhere that records whether a
-- customer wants own-truck delivery vs. a courier they arrange themselves (e.g. Lalamove) vs.
-- pickup (see supabase_orders_sync_tables.sql/supabase_online_order_portal_status_update.sql) -
-- that choice has always been a staff/customer conversation, never stored. So this can't be gated
-- by a database flag: the BOT itself is responsible for only calling schedule_delivery_date after
-- the customer has said in conversation that they want the store's own truck, not a courier or
-- pickup - see the schedule_delivery_date tool's description in index.ts.
--
-- These two RPCs are the anon-callable, customer-facing counterparts of the staff-only
-- admin_create_delivery_stop (supabase_delivery_stop_route_tagging.sql) - same underlying
-- DeliveryStops insert/ForDelivery flip/RouteName snapshot logic, but keyed directly by the OrderID
-- the customer already has, with NO staff auth and NO ownership check - same trust model as every
-- other public_get_online_order_* RPC (knowing the order number is treated as proof enough).
--
-- Two rules enforced here that the staff booking flow does NOT have, per direct decision since this
-- is now unsupervised (no staff reviews it before it's booked):
--   1. Minimum 2 days' notice (current_date + 2) - staff self-booking has no such restriction, but
--      self-service booking needs to give the warehouse time to actually plan the truck's load/
--      route, since nobody reviews this before it happens.
--   2. The order must currently be eligible the same way admin_list_deliverable_online_orders
--      already defines it (ForDelivery is not true, Status in Confirmed/Printed/To Ship/Shipped,
--      not a walk-in/in-store sale) - re-checked SERVER-SIDE in both RPCs below, never trusting
--      that the bot only ever offers a date for an order it already confirmed was eligible.
-- The existing no-Mondays rule is also re-enforced here independently (not shared code with
-- admin_create_delivery_stop, since that function requires staff auth).
--
-- public_get_delivery_scheduling_options: read-only first step - checks eligibility and returns
-- either one row with eligible=false + a plain-language reason, or one row per offered candidate
-- date (the next 5 valid dates) when eligible, alongside the order's own DeliveryFee (the actual
-- amount already recorded on this order, if Pancake/staff has already set one - see
-- OnlineOrders."DeliveryFee" / supabase_delivery_receipt.sql) plus warehouse_name/shipping_address
-- so the Edge Function can compute a fresh distance-based ESTIMATE (same formula as the existing
-- compute_delivery_quote tool) when DeliveryFee is still null - see the get_delivery_scheduling_
-- options case in index.ts. The bot shows whichever fee results, AND the candidate dates, to the
-- customer and gets them to confirm both BEFORE calling public_schedule_online_order_delivery - per
-- direct request to share the delivery price and confirm before booking, same "never act without an
-- explicit customer choice" discipline as send_item_image.
--
-- public_schedule_online_order_delivery: the actual booking - tagged clearly in the Delivery
-- calendar as bot-originated (CreatedBy = 'AI Assistant (Messenger)', a Notes value saying so) so
-- staff can immediately tell it wasn't a human booking when they see it on docs/delivery.html.

drop function if exists public.public_get_delivery_scheduling_options(text);

create or replace function public.public_get_delivery_scheduling_options(p_order_id text)
returns table(
  eligible boolean,
  reason text,
  order_id text,
  customer_name text,
  delivery_fee numeric,
  warehouse_name text,
  shipping_address text,
  candidate_date date
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text := trim(p_order_id);
  v_status text;
  v_for_delivery boolean;
  v_received_at_shop boolean;
  v_customer_name text;
  v_delivery_fee numeric;
  v_warehouse_name text;
  v_shipping_address text;
  v_date date;
  v_offered int := 0;
begin
  select o."Status", o."ForDelivery", o."ReceivedAtShop", o."CustomerName"::text, o."DeliveryFee",
         w."Name"::text, o."ShippingAddress"::text
    into v_status, v_for_delivery, v_received_at_shop, v_customer_name, v_delivery_fee,
         v_warehouse_name, v_shipping_address
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where o."OrderID" = v_order_id;

  if not found then
    eligible := false;
    reason := 'No order found with that number.';
    order_id := v_order_id;
    return next;
    return;
  end if;

  if v_received_at_shop is true then
    eligible := false;
    reason := 'This order was recorded as an in-store sale, not an online delivery order.';
    order_id := v_order_id;
    customer_name := v_customer_name;
    return next;
    return;
  end if;

  if v_for_delivery is true then
    eligible := false;
    reason := 'This order already has a delivery date scheduled.';
    order_id := v_order_id;
    customer_name := v_customer_name;
    return next;
    return;
  end if;

  if lower(coalesce(v_status, '')) not in ('confirmed', 'printed', 'to ship', 'shipped') then
    eligible := false;
    reason := 'This order is not yet ready to schedule a delivery date for (current status: ' || coalesce(v_status, 'unknown') || ').';
    order_id := v_order_id;
    customer_name := v_customer_name;
    return next;
    return;
  end if;

  v_date := current_date + 2;
  while v_offered < 5 loop
    if extract(dow from v_date) <> 1 then
      eligible := true;
      reason := null;
      order_id := v_order_id;
      customer_name := v_customer_name;
      delivery_fee := v_delivery_fee;
      warehouse_name := v_warehouse_name;
      shipping_address := v_shipping_address;
      candidate_date := v_date;
      return next;
      v_offered := v_offered + 1;
    end if;
    v_date := v_date + 1;
  end loop;
end;
$$;

grant execute on function public.public_get_delivery_scheduling_options(text) to anon;

drop function if exists public.public_schedule_online_order_delivery(text, date);

create or replace function public.public_schedule_online_order_delivery(p_order_id text, p_delivery_date date)
returns table(order_id text, delivery_date date, route_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text := trim(p_order_id);
  v_status text;
  v_for_delivery boolean;
  v_received_at_shop boolean;
  v_truck_id uuid;
  v_next_sequence int;
  v_route_name text;
begin
  if p_delivery_date is null then
    raise exception 'A delivery date is required.';
  end if;

  if p_delivery_date < current_date + 2 then
    raise exception 'Delivery dates need at least 2 days notice.';
  end if;

  if extract(dow from p_delivery_date) = 1 then
    raise exception 'Mondays are not available for delivery.';
  end if;

  select o."Status", o."ForDelivery", o."ReceivedAtShop"
    into v_status, v_for_delivery, v_received_at_shop
  from public."OnlineOrders" o
  where o."OrderID" = v_order_id;

  if not found then
    raise exception 'No order found with that number.';
  end if;

  if v_received_at_shop is true then
    raise exception 'This order was recorded as an in-store sale, not an online delivery order.';
  end if;

  if v_for_delivery is true then
    raise exception 'This order already has a delivery date scheduled.';
  end if;

  if lower(coalesce(v_status, '')) not in ('confirmed', 'printed', 'to ship', 'shipped') then
    raise exception 'This order is not yet ready to schedule a delivery date for.';
  end if;

  select "RouteName" into v_route_name
  from public."DeliveryRouteSchedule"
  where "DayOfWeek" = extract(dow from p_delivery_date);

  select "TruckID" into v_truck_id from public."DeliveryTrucks" where "IsActive" is true order by "CreatedAtUtc" limit 1;
  if v_truck_id is null then
    raise exception 'No active delivery truck is configured - ask the customer to contact staff directly.';
  end if;

  select coalesce(max("StopSequence") + 1, 0) into v_next_sequence
  from public."DeliveryStops"
  where "DeliveryDate" = p_delivery_date and "TruckID" = v_truck_id;

  begin
    insert into public."DeliveryStops" ("OrderID", "TruckID", "DeliveryDate", "StopSequence", "Notes", "CreatedBy", "RouteName")
    values (
      v_order_id, v_truck_id, p_delivery_date, v_next_sequence,
      'Self-scheduled by customer via Messenger AI assistant.', 'AI Assistant (Messenger)', v_route_name
    );
  exception when unique_violation then
    raise exception 'This order is already scheduled for that date.';
  end;

  update public."OnlineOrders" set "ForDelivery" = true where "OrderID" = v_order_id;

  order_id := v_order_id;
  delivery_date := p_delivery_date;
  route_name := v_route_name;
  return next;
end;
$$;

grant execute on function public.public_schedule_online_order_delivery(text, date) to anon;
