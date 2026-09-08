-- Manual Customer Name for a delivery stop, alongside the manual Address it already had. Per
-- "hey can you help me in the deliver if the customer is POS WALKIN ORDERS and Address is Walkin
-- can you ask the user for Address and Name of customer once its assigned. This will fall under
-- the printout too".
--
-- BACKGROUND. A sale rung up at the POS with no real customer picked syncs from Pancake with
-- CustomerName literally "POS WALKIN ORDERS" and ShippingAddress literally "Walkin" - neither is
-- an actual customer identity or a place a driver can be sent to. Assigning one of these to a
-- delivery already prompted for a manual address when ShippingAddress was BLANK (see
-- confirmAssign/openNoAddressModal, js/delivery.js, and admin_update_delivery_stop_geocode
-- below) - "Walkin" is not blank, so that prompt never fired for it, and there was nowhere to
-- record a real customer name at all.
--
-- THE FIX. js/delivery.js now treats "Walkin" the same as a blank address (isPlaceholderAddress),
-- and detects the "POS WALKIN ORDERS" placeholder (isWalkInPlaceholderOrder) to also ask for a
-- Customer Name at the same moment. Both are stored on DeliveryStops - never written back to
-- OnlineOrders.CustomerName/ShippingAddress (Pancake-synced fields a manual entry must not drift
-- from or get silently overwritten by) - and substituted in on every read, so the manifest print,
-- the delivery receipt/invoice print, the day-detail table, and the Driver Route View all show the
-- real name/address instead of the placeholder.

alter table public."DeliveryStops" add column if not exists "ManualCustomerName" varchar(255);

-- ============================================================================
-- admin_update_delivery_stop_geocode gains a trailing p_customer_name - dropped by OID first (an
-- added parameter is a distinct overload as far as Postgres is concerned, and PostgREST calls by
-- argument name, so an old 7-arg overload left beside this one would make every call ambiguous,
-- PGRST203).

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'admin_update_delivery_stop_geocode'
  loop
    raise notice 'Dropping overload: %', r.signature;
    execute format('drop function %s', r.signature);
  end loop;
end;
$$;

-- p_customer_name default null and coalesce-preserved (only overwritten when a non-blank value is
-- actually sent): the "Retry Map" button and every other existing caller re-geocode an address
-- without knowing or touching the name, and must not blank one out that was entered earlier.
create or replace function public.admin_update_delivery_stop_geocode(
  p_admin_username text,
  p_admin_password text,
  p_stop_id uuid,
  p_geocoded_address text,
  p_latitude numeric,
  p_longitude numeric,
  p_geocode_status text,
  p_customer_name text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."DeliveryStops"
  set "GeocodedAddress" = p_geocoded_address,
      "Latitude" = p_latitude,
      "Longitude" = p_longitude,
      "GeocodeStatus" = p_geocode_status,
      "GeocodedAtUtc" = now(),
      "ManualCustomerName" = coalesce(nullif(trim(p_customer_name), ''), "ManualCustomerName")
  where "StopID" = p_stop_id;
end;
$$;

grant execute on function public.admin_update_delivery_stop_geocode(text, text, uuid, text, numeric, numeric, text, text) to anon;

-- ============================================================================
-- admin_list_delivery_stops (the calendar day-detail table, Driver Route View and print manifest
-- all read this). The live version is actually the one from supabase_delivery_tables.sql (19
-- columns, created_by + note_print added after route_tagging.sql's 17-column copy) - copying the
-- older shape here made Postgres reject this as a return-type change (42P13, "Row type defined by
-- OUT parameters is different"), since create-or-replace only tolerates an IDENTICAL output shape.
-- Explicit drop first, then recreate with the full current shape - only the customer_name
-- expression actually changes.
drop function if exists public.admin_list_delivery_stops(text, text, date, date);

create or replace function public.admin_list_delivery_stops(p_admin_username text, p_admin_password text, p_start_date date, p_end_date date)
returns table(
  stop_id uuid,
  delivery_date date,
  truck_id uuid,
  truck_name text,
  stop_sequence int,
  order_id text,
  customer_name text,
  status text,
  shipping_address text,
  money_to_collect numeric,
  balance numeric,
  notes text,
  latitude numeric,
  longitude numeric,
  geocode_status text,
  geocoded_address text,
  route_name text,
  created_by text,
  note_print text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s."StopID", s."DeliveryDate", s."TruckID", t."TruckName"::text, s."StopSequence",
           o."OrderID"::text,
           coalesce(nullif(trim(s."ManualCustomerName"), ''), o."CustomerName")::text,
           o."Status"::text, o."ShippingAddress"::text,
           o."MoneyToCollect", o."Balance", s."Notes"::text,
           s."Latitude", s."Longitude", s."GeocodeStatus"::text, s."GeocodedAddress"::text,
           s."RouteName"::text, s."CreatedBy"::text,
           coalesce(
             nullif(trim(o."NotePrint"::text), ''),
             (select string_agg(nullif(trim(l."Note"::text), ''), '; ' order by l."LineID")
                from public."OnlineOrderLines" l
                where l."OrderID" = o."OrderID" and nullif(trim(l."Note"::text), '') is not null)
           ) as note_print
    from public."DeliveryStops" s
    join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    join public."DeliveryTrucks" t on t."TruckID" = s."TruckID"
    where s."DeliveryDate" >= p_start_date and s."DeliveryDate" < p_end_date
    order by s."DeliveryDate", s."StopSequence";
end;
$$;

grant execute on function public.admin_list_delivery_stops(text, text, date, date) to anon;

-- ============================================================================
-- admin_get_delivery_receipt (the delivery receipt/invoice print, and the Driver Route View's own
-- order-detail modal).
--
-- THIS ONE HAD DRIFTED IN THE REPO ITSELF: two later migrations each extended it in a different
-- direction from the same ancestor - supabase_delivery_receipt_line_details.sql added line_id (for
-- the Driver Route View's attachments feature, js/delivery.js's openDriverOrderDetail) but not the
-- confirmed_by/warehouse_name/warehouse_address/money_to_collect/amount_paid/discount/balance/
-- line_amount columns; supabase_delivery_receipt.sql added those (for the Invoice print,
-- js/invoice.js) but not line_id. Neither file's copy of the shape matches whichever one is
-- actually live, so a plain create-or-replace here failed with 42P13 regardless of which of the
-- two return shapes was tried. Fixed two ways: an explicit drop first (so a shape mismatch can
-- never fail this migration again), and a return shape that is the UNION of both extensions - the
-- full set of columns every consumer (deliveryReceipt.js, invoice.js, delivery.js) actually reads
-- by name - so this migration also repairs whichever half was missing live, not just adds the
-- walk-in fields.
--
-- Unlike admin_list_delivery_stops above, this one has no client-side fallback at all
-- (js/deliveryReceipt.js and js/invoice.js print shipping_address/customer_name straight from
-- here) - so BOTH the "Walkin"-as-placeholder address logic and the manual-name substitution have
-- to happen here in SQL, not left for the browser to reconcile.
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
  line_id text,
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
  v_manual_customer_name text;
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

  select s."OrderID", s."GeocodedAddress", s."ManualCustomerName"
    into v_order_id, v_geocoded_address, v_manual_customer_name
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

  -- Manually-entered-name override, per the header comment above - preferred whenever one was
  -- actually typed at assignment time.
  v_customer_name := coalesce(nullif(trim(v_manual_customer_name), ''), v_customer_name);

  -- Same manually-entered-address fallback convention as the Delivery day-detail table
  -- (js/delivery.js's isPlaceholderAddress) - covers a stop whose order has no real
  -- ShippingAddress on file, either genuinely blank or Pancake's own "Walkin" placeholder text.
  v_shipping_address := case
    when v_shipping_address is null or trim(v_shipping_address) = '' or lower(trim(v_shipping_address)) = 'walkin'
      then v_geocoded_address
    else v_shipping_address
  end;

  for v_line in
    select l."LineID"::text as line_id, l."Description"::text as description, l."Quantity" as quantity,
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
    line_id := v_line.line_id;
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
    line_id := null;
    line_description := null;
    line_quantity := null;
    line_amount := null;
    line_note := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_delivery_receipt(text, text, uuid) to anon;

notify pgrst, 'reload schema';

-- Verification. One row per function.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_update_delivery_stop_geocode',
    'admin_list_delivery_stops',
    'admin_get_delivery_receipt'
  )
order by p.proname, arguments;
