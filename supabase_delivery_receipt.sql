-- Per-order printable Delivery Receipt (see docs/delivery-receipt.html), linked from a "Print"
-- button on each row of the Delivery day-detail Stops table (js/delivery.js). Mirrors the
-- Pancake-generated delivery receipt layout the shop already prints from Pancake itself - same
-- company letterhead (+ DTI/TIN No.), Order #/Creation date, Receiver name/address/phone,
-- Products table (Description/Qty), the order's own "Additional NOTE" (NotePrint - see
-- supabase_orders_sync_tables.sql), and Delivery Fee - so staff can reprint it from the portal
-- without needing to go back into Pancake.
--
-- Takes a DeliveryStops."StopID" (not a bare OrderID) so the manually-entered-address fallback
-- (DeliveryStops."GeocodedAddress", used when an order has no ShippingAddress on file - same
-- convention as the Delivery day-detail table itself) is available. Reads straight from the
-- persisted OnlineOrders/OnlineOrderLines tables (no live Pancake call - a scheduled stop's
-- order has already been synced by the time it's assigned a delivery date).
--
-- One row per order line, with the shared header fields repeated on every row (same flat-row
-- shape as admin_get_online_order_detail_live) - the client (js/deliveryReceipt.js) reads the
-- header off row 0 and renders every row's line_description/line_quantity as a Products table
-- row. If the order genuinely has zero synced lines, a single sentinel row is still returned so
-- the header still renders (line_no IS NULL signals "not a real line" to the client, same
-- sentinel-row convention used elsewhere in this codebase).
drop function if exists public.admin_get_delivery_receipt(text, text, uuid);

create or replace function public.admin_get_delivery_receipt(
  p_admin_username text,
  p_admin_password text,
  p_stop_id uuid
)
returns table(
  order_id text,
  order_date date,
  customer_name text,
  shipping_address text,
  shipping_phone text,
  delivery_fee numeric,
  note_print text,
  line_no int,
  line_description text,
  line_quantity numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text;
  v_geocoded_address text;
  v_order_date date;
  v_customer_name text;
  v_shipping_address text;
  v_shipping_phone text;
  v_delivery_fee numeric;
  v_note_print text;
  v_line record;
  v_line_no int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select s."OrderID", s."GeocodedAddress" into v_order_id, v_geocoded_address
  from public."DeliveryStops" s
  where s."StopID" = p_stop_id;

  if v_order_id is null then
    raise exception 'Delivery stop not found.';
  end if;

  select o."Date", o."CustomerName"::text, o."ShippingAddress"::text, o."ShippingPhone"::text, o."DeliveryFee", o."NotePrint"::text
    into v_order_date, v_customer_name, v_shipping_address, v_shipping_phone, v_delivery_fee, v_note_print
  from public."OnlineOrders" o
  where o."OrderID" = v_order_id;

  -- Same manually-entered-address fallback convention as the Delivery day-detail table
  -- (js/delivery.js's displayAddress) - covers a stop whose order has no ShippingAddress on
  -- file (a manually-typed address from the "no shipping address" confirmation prompt).
  v_shipping_address := coalesce(nullif(trim(v_shipping_address), ''), v_geocoded_address);

  for v_line in
    select l."Description"::text as description, l."Quantity" as quantity
    from public."OnlineOrderLines" l
    where l."OrderID" = v_order_id
    order by l."LineID"
  loop
    v_line_no := v_line_no + 1;
    order_id := v_order_id;
    order_date := v_order_date;
    customer_name := v_customer_name;
    shipping_address := v_shipping_address;
    shipping_phone := v_shipping_phone;
    delivery_fee := v_delivery_fee;
    note_print := v_note_print;
    line_no := v_line_no;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    return next;
  end loop;

  if v_line_no = 0 then
    order_id := v_order_id;
    order_date := v_order_date;
    customer_name := v_customer_name;
    shipping_address := v_shipping_address;
    shipping_phone := v_shipping_phone;
    delivery_fee := v_delivery_fee;
    note_print := v_note_print;
    line_no := null;
    line_description := null;
    line_quantity := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_delivery_receipt(text, text, uuid) to anon;
