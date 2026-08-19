-- Extends admin_get_delivery_receipt (supabase_delivery_receipt.sql) with each line's LineID and
-- Note (Pancake's per-item note - separate from the order-level NotePrint already returned) - per
-- "can you show the Note, Quantity and the Attachments too" on the Driver Route View's order
-- detail modal (js/delivery.js's openDriverOrderDetail). line_id is what lets the client look up
-- that line's attachments via the existing admin_list_online_order_line_attachments RPC
-- (supabase_online_order_line_attachments.sql) - the same one Online Order Lines already uses, so
-- no new attachments RPC is needed. Still returns no price/cost fields at all - the driver-facing
-- view stays price-free. docs/js/deliveryReceipt.js (the Print receipt page) also calls this
-- function but reads columns by name, so the two new trailing columns are backward compatible
-- with it unchanged.
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
  line_id text,
  line_description text,
  line_quantity numeric,
  line_note text
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
    select l."LineID"::text as line_id, l."Description"::text as description, l."Quantity" as quantity, l."Note"::text as note
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
    line_id := v_line.line_id;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    line_note := v_line.note;
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
    line_id := null;
    line_description := null;
    line_quantity := null;
    line_note := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_delivery_receipt(text, text, uuid) to anon;
