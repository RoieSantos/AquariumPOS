-- Delivery Receipt / Invoice only after a proper To Ship - per "if an order is needing a serial and no serials
-- has been tagged.. can we not print a delivery receipt?" and the cause found: "the order is confirmed and
-- they schedule this order in the calendar ahead of time. then when the time comes of delivery they just
-- print it and did not do proper to-ship" (e.g. AO-00091: Confirmed -> scheduled -> printed -> Delivered,
-- never To Ship, so no serial was ever picked).
--
--   staff_get_delivery_stop_print_block(stop) - null = OK to print, else why not:
--     1. the order hasn't been through To Ship - Online / Walk-in: Status To Ship or later
--        (_order_status_past_to_ship - incl. Pancake's numeric codes), or a picked-up walk-in, and a custom
--        walk-in not still To Assign / Assigned with the makers; Advance: ToShipAtUtc / ShippedAtUtc /
--        DeliveredAtUtc set; a draft AO (not confirmed) never. To Ship is where the serials are picked.
--     2. a serial-tracked item is still short of a SOLD serial (an order shipped short at a non-production
--        store's To Ship) - fixed with "Tag serial" on the order card. A reserved serial isn't tagged yet.
--     Checked by the Delivery page's Print / Print Invoice (js/delivery.js) and again by
--     delivery-receipt.html / invoice.html on load (js/deliverySerialGate.js), so a saved link is blocked
--     too. Not inside admin_get_delivery_receipt: that also feeds the Job Order and the driver's stop
--     details, which must keep working. Job Order printing is not blocked.
--   _fulfilled_order_serial_needs - re-created so the advance check works for the Delivery Team too.
--   _serial_order_is_fulfilled - re-created to also take To Ship (Online status 'to ship', Advance
--     ToShipAtUtc): an order packed short at To Ship can get its serials with "Tag serial" before it leaves.
--
-- Run AFTER supabase_tag_serials_fulfilled_order.sql. Safe to re-run. Don't re-run
-- supabase_tag_serials_fulfilled_order.sql afterwards (it would put back the older _serial_order_is_fulfilled
-- / _fulfilled_order_serial_needs) - if you must, run this file again after it.

-- An online order status at To Ship or later. Pancake's own words plus the numeric codes the Status column
-- sometimes holds (2 = Shipped, 3 = Delivered, 8 = To Ship - MapStatusForApi).
create or replace function public._order_status_past_to_ship(p_status text)
returns boolean
language sql
immutable
as $$
  select lower(trim(coalesce(p_status, ''))) in
    ('to ship', 'packing', 'packed', 'in-transit', 'shipped', 'delivered', 'received', 'completed', '2', '3', '8');
$$;

create or replace function public._serial_order_is_fulfilled(p_link text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_link ilike 'ADV-%' then exists (
      select 1 from public."AdvanceOrderProduction" p
      where p."TransactionNo" = substr(p_link, 5)
        and (p."ToShipAtUtc" is not null or p."ShippedAtUtc" is not null or p."DeliveredAtUtc" is not null))
    else exists (
      select 1 from public."OnlineOrders" o
      where o."OrderID" = p_link
        and (public._order_status_past_to_ship(o."Status")
             or (o."ReceivedAtShop" is true and o."PickedUpAtUtc" is not null)))
  end;
$$;

revoke execute on function public._serial_order_is_fulfilled(text) from public, anon, authenticated;

-- Re-created: Advance now reads the internal _advance_order_line_items / _advance_order_serials (same
-- numbers as staff_get_advance_order_serial_requirements) - that RPC refuses anyone who can't open the
-- advance order, e.g. the Delivery Team printing its receipt.
create or replace function public._fulfilled_order_serial_needs(
  p_admin_username text, p_admin_password text, p_doc_type text, p_doc_no text)
returns table(item_code text, variation_id text, description text, quantity_total int, quantity_tagged int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_link text := public._serial_order_link(p_doc_type, p_doc_no);
begin
  if v_link ilike 'ADV-%' then
    return query
      select li.item_code, (array_agg(li.variation_id order by li.line_no))[1], (array_agg(li.description order by li.line_no))[1],
             sum(li.quantity)::int,
             (select count(*)::int from public._advance_order_serials(substr(v_link, 5)) s
              where s."Status" = 'SOLD' and s."ItemCode" = li.item_code)
      from public._advance_order_line_items(substr(v_link, 5)) li
      where li.needs_serial
      group by li.item_code;
  else
    return query
      select r.item_code, (array_agg(r.variation_id order by r.line_id))[1], (array_agg(r.description order by r.line_id))[1],
             sum(r.quantity_needed)::int,
             (select count(*)::int from public."ItemSerialTracking" s
              where s."SoldOnlineOrderId" = v_link and s."Status" = 'SOLD' and s."ItemCode" = r.item_code)
      from public.admin_get_online_order_serial_requirements(p_admin_username, p_admin_password, v_link) r
      group by r.item_code;
  end if;
end;
$$;

revoke execute on function public._fulfilled_order_serial_needs(text, text, text, text) from public, anon, authenticated;


-- An earlier draft of this file had the serial half only.
drop function if exists public.staff_get_delivery_stop_missing_serials(text, text, uuid);
drop function if exists public.staff_get_delivery_stop_print_block(text, text, uuid);

create or replace function public.staff_get_delivery_stop_print_block(
  p_admin_username text,
  p_admin_password text,
  p_stop_id uuid
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text;
  v_adv text;
  v_automated text;
  v_label text;
  v_status text;
  v_picked_up boolean;
  v_to_ship_done boolean;
  v_missing text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select s."OrderID", s."AdvanceTransactionNo", s."AutomatedOrderNo" into v_order_id, v_adv, v_automated
  from public."DeliveryStops" s where s."StopID" = p_stop_id;
  if not found then
    raise exception 'Delivery stop not found.';
  end if;

  -- 1. To Ship done?
  if v_automated is not null then
    return format('Order %s isn''t confirmed yet, so it can''t be delivered. Confirm it, then do To Ship on Online Orders (pick its serials there), then print.', v_automated);
  elsif v_adv is not null then
    v_label := 'ADV-' || v_adv;
    select (p."ToShipAtUtc" is not null or p."ShippedAtUtc" is not null or p."DeliveredAtUtc" is not null),
           public._advance_order_prod_status(p)
      into v_to_ship_done, v_status
    from public."AdvanceOrderProduction" p where p."TransactionNo" = v_adv;
    if not coalesce(v_to_ship_done, false) then
      return format('Advance order %s is still %s - it hasn''t been through Ready to Ship. Do Ready to Ship on Online Orders > Advance Orders first (that''s where its serials are picked), then print.',
                    v_label, coalesce(v_status, 'New'));
    end if;
  else
    v_label := v_order_id;
    select o."Status", (o."ReceivedAtShop" is true and o."PickedUpAtUtc" is not null)
      into v_status, v_picked_up
    from public."OnlineOrders" o where o."OrderID" = v_order_id;
    if not (public._order_status_past_to_ship(v_status) or coalesce(v_picked_up, false)) then
      return format('Order %s is still %s - it hasn''t been through To Ship. Do To Ship on Online Orders first (that''s where its serials are picked), then print.',
                    v_order_id, case lower(trim(coalesce(v_status, ''))) when 'printed' then 'Confirmed' when '' then 'not confirmed' else v_status end);
    end if;
    -- A walk-in is Shipped from the POS on - but a custom one still with the makers isn't ready
    -- (supabase_walkin_order_portal_status.sql: To Assign / Assigned until every part is Production Done).
    v_status := public._walkin_order_stage(v_order_id);
    if v_status in ('To Assign', 'Assigned') then
      return format('Walk-in %s is still %s - it''s in production. Mark every part Production Done first, then print.', v_order_id, v_status);
    end if;
  end if;

  -- 2. Every serial-tracked unit tagged?
  select string_agg(n.item_code || ' (' || n.quantity_tagged || ' of ' || n.quantity_total || ' tagged)', ', ' order by n.item_code)
    into v_missing
  from public._fulfilled_order_serial_needs(p_admin_username, p_admin_password,
         case when v_order_id is not null then 'online' else 'advance' end, coalesce(v_order_id, v_adv)) n
  where n.quantity_tagged < n.quantity_total;
  if v_missing is not null then
    return format('Order %s can''t be delivered yet - no serial tagged for: %s. A Super User, Serial Admin or Production Manager must tag them first (Online Orders > open the order > Stock > Tag serial), then print.',
                  v_label, v_missing);
  end if;

  return null;
end;
$$;

grant execute on function public.staff_get_delivery_stop_print_block(text, text, uuid) to anon;
