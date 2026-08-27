-- Per-order printable Delivery Receipt (see docs/delivery-receipt.html), linked from a "Print"
-- button on each row of the Delivery day-detail Stops table (js/delivery.js). Mirrors the
-- Pancake-generated delivery receipt layout the shop already prints from Pancake itself - same
-- company letterhead (+ DTI/TIN No.), Order #/Creation date, Receiver name/address/phone,
-- Products table (Description/Qty), the order's own "Additional NOTE" (NotePrint - see
-- supabase_orders_sync_tables.sql), and Delivery Fee - so staff can reprint it from the portal
-- without needing to go back into Pancake.
--
-- Also backs docs/invoice.html/js/invoice.js - an itemized "Invoice" print layout (Sales Staff,
-- branch/Location, per-line Amount, Total/Discount/Amount Paid/Balance) for the same stop -
-- see this function's extra output columns below (confirmed_by onward).
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
--
-- confirmed_by/warehouse_name/warehouse_address/money_to_collect/amount_paid/discount/balance/
-- line_amount: added so this same function can also back the Invoice print page
-- (docs/invoice.html/js/invoice.js) - an itemized alternative to the plain Delivery Receipt, for
-- the same stop. docs/js/deliveryReceipt.js reads fields by name and ignores the extras, so this
-- doesn't affect the existing Delivery Receipt page. warehouse_name/warehouse_address resolve
-- the order's own branch (Warehouses."Address" - the delivery-map geocoding column, doubling as
-- this branch's own physical address for the invoice header) - deliberately NOT the global
-- company letterhead address (see companyBranding.js/CompanyInfo), since there's no per-branch
-- TIN/DTI anywhere in this schema, only a single company-wide CompanyInfo row.
--
-- line_amount: NOT OnlineOrderLines."NetAmount" - confirmed against a real order (via the
-- Online Order Lines admin view, docs/online-order-lines.html) that NetAmount is reliably left
-- null by whatever sync path populates this table, while GrossAmount is always set. So this uses
-- coalesce("GrossAmount", "NetAmount", "Price" * "Quantity") - GrossAmount first (the field
-- that's actually populated), NetAmount as a fallback for the rare row where it IS set instead,
-- Price*Quantity as a last resort if somehow both are null.
--
-- note_print: OnlineOrders."NotePrint" as-is - Pancake's own order-level print note (general
-- delivery instructions, e.g. "AM Delivery before 12"), only populated by the "compute once,
-- cache forever"/periodic-recheck detail-fetch backfill (see the "GlassThickness"/"NotePrint"
-- column comments in supabase_orders_sync_tables.sql). No longer falls back to a concatenation of
-- line-level notes here - per-line notes (line_note below) are now printed directly under their
-- own line instead of being merged into this single header blob, so a per-product spec note (e.g.
-- a custom aquarium's dimensions/sealant note) stays attached to the line it actually describes.
--
-- line_note: OnlineOrderLines."Note" for this line - populated by the regular line sync (not the
-- backfill-only path), so it's reliably present even for an order whose header-level NotePrint
-- hasn't been backfilled yet. Rendered by the client directly under its matching product row.
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
  confirmed_by text,
  warehouse_name text,
  warehouse_address text,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
  balance numeric,
  line_no int,
  line_description text,
  line_quantity numeric,
  line_amount numeric,
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
  v_confirmed_by text;
  v_warehouse_name text;
  v_warehouse_address text;
  v_money_to_collect numeric;
  v_amount_paid numeric;
  v_discount numeric;
  v_balance numeric;
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

  select o."Date", o."CustomerName"::text, o."ShippingAddress"::text, o."ShippingPhone"::text, o."DeliveryFee", o."NotePrint"::text,
         o."ConfirmedBy"::text, w."Name"::text, w."Address"::text,
         o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance"
    into v_order_date, v_customer_name, v_shipping_address, v_shipping_phone, v_delivery_fee, v_note_print,
         v_confirmed_by, v_warehouse_name, v_warehouse_address,
         v_money_to_collect, v_amount_paid, v_discount, v_balance
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where o."OrderID" = v_order_id;

  -- Same manually-entered-address fallback convention as the Delivery day-detail table
  -- (js/delivery.js's displayAddress) - covers a stop whose order has no ShippingAddress on
  -- file (a manually-typed address from the "no shipping address" confirmation prompt).
  v_shipping_address := coalesce(nullif(trim(v_shipping_address), ''), v_geocoded_address);

  for v_line in
    select l."Description"::text as description, l."Quantity" as quantity,
           coalesce(l."GrossAmount", l."NetAmount", l."Price" * l."Quantity") as amount,
           nullif(trim(l."Note"::text), '') as note
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
    confirmed_by := v_confirmed_by;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    money_to_collect := v_money_to_collect;
    amount_paid := v_amount_paid;
    discount := v_discount;
    balance := v_balance;
    line_no := v_line_no;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    line_amount := v_line.amount;
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
    confirmed_by := v_confirmed_by;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    money_to_collect := v_money_to_collect;
    amount_paid := v_amount_paid;
    discount := v_discount;
    balance := v_balance;
    line_no := null;
    line_description := null;
    line_quantity := null;
    line_amount := null;
    line_note := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_delivery_receipt(text, text, uuid) to anon;
