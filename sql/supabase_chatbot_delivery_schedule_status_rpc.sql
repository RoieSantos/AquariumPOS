-- AI Messenger chatbot: "where is my delivery" for an order already scheduled on the store's own
-- truck - answers whether a given Online Order has a DeliveryStops row for TODAY (see
-- sql/supabase_delivery_tables.sql), as opposed to public_get_delivery_scheduling_options
-- (sql/supabase_chatbot_delivery_scheduling_rpc.sql), which is the opposite case: booking a date
-- for an order that ISN'T scheduled yet, and explicitly excludes anything already ForDelivery=true.
--
-- Per that same file's header comment: there is no data field anywhere recording whether a
-- customer wants the store's own truck vs. a courier they arrange themselves (e.g. Lalamove) vs.
-- pickup - that's always a staff/customer conversation, never stored. So this RPC can only ever
-- answer for orders that DO have a real DeliveryStops row (i.e. staff, or the customer via
-- schedule_delivery_date, actually booked the store's own truck) - the bot is responsible for
-- asking the customer which kind of delivery this is BEFORE calling this, same discipline as
-- schedule_delivery_date already requires. See the get_delivery_schedule_status tool in
-- supabase/functions/_shared/chatbot-engine.ts.
--
-- Same trust model as every other public_get_online_order_* / public_get_delivery_scheduling_options
-- RPC - no ownership check, knowing the order number is treated as proof enough.
--
-- Picks the single most relevant DeliveryStops row when more than one exists for an order (rare -
-- the unique constraint is per (OrderID, DeliveryDate), so a re-scheduled/moved order could in
-- theory still have an old row if ever moved incorrectly): prefers today-or-later over anything in
-- the past, then whichever date is closest to today.

drop function if exists public.public_get_delivery_schedule_status(text);

create or replace function public.public_get_delivery_schedule_status(p_order_id text)
returns table(
  found boolean,
  order_id text,
  for_delivery boolean,
  status text,
  scheduled_date date,
  is_today boolean,
  route_name text,
  truck_name text,
  stop_sequence int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text := trim(p_order_id);
  v_for_delivery boolean;
  v_status text;
  v_stop_date date;
  v_route_name text;
  v_truck_name text;
  v_stop_sequence int;
begin
  select o."ForDelivery", o."Status"::text
    into v_for_delivery, v_status
  from public."OnlineOrders" o
  where o."OrderID" = v_order_id
    and o."ReceivedAtShop" is not true;

  if not found then
    found := false;
    order_id := v_order_id;
    return next;
    return;
  end if;

  select s."DeliveryDate", s."RouteName"::text, t."TruckName"::text, s."StopSequence"
    into v_stop_date, v_route_name, v_truck_name, v_stop_sequence
  from public."DeliveryStops" s
  join public."DeliveryTrucks" t on t."TruckID" = s."TruckID"
  where s."OrderID" = v_order_id
  order by (s."DeliveryDate" >= current_date) desc, abs(s."DeliveryDate" - current_date)
  limit 1;

  found := true;
  order_id := v_order_id;
  for_delivery := coalesce(v_for_delivery, false);
  status := v_status;
  scheduled_date := v_stop_date;
  is_today := (v_stop_date = current_date);
  route_name := v_route_name;
  truck_name := v_truck_name;
  stop_sequence := v_stop_sequence;
  return next;
end;
$$;

grant execute on function public.public_get_delivery_schedule_status(text) to anon;
