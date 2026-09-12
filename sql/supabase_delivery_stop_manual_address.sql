-- Full manual address override for a delivery stop, closing a gap left by
-- supabase_delivery_walkin_manual_details.sql / supabase_delivery_stop_manual_note_print.sql.
-- Per "is the address editable too?" - turned out it wasn't, not fully: those two migrations made
-- Customer Name/Contact Number/Notes/Print Note overwritable via "Edit Details" regardless of what
-- Pancake had on file, but Address only worked that way when the order's real ShippingAddress was
-- blank or Pancake's "Walkin" placeholder (isPlaceholderAddress, js/delivery.js). If an order
-- already had a REAL address from Pancake, "Edit Details" would re-geocode the map pin to a typed
-- address but the address TEXT shown in the table and printed on the manifest/receipt/invoice kept
-- showing Pancake's original text - editing it didn't visibly do anything except move the pin.
--
-- THE FIX. A new "ManualAddress" column, same convention as ManualCustomerName/ManualContactNumber/
-- ManualNotePrint: stored on DeliveryStops (never written back to Pancake-synced
-- OnlineOrders."ShippingAddress"), and coalesced in ahead of the Pancake address everywhere
-- shipping_address is read (admin_list_delivery_stops, admin_get_delivery_receipt) - once set, a
-- typed address always wins, real Pancake address or not.
--
-- ONE DELIBERATE TRADEOFF, since this changes address specifically (unlike name/note, an address
-- CAN legitimately change on Pancake's side after a stop is scheduled): admin_update_delivery_stop_
-- geocode only writes ManualAddress when the caller explicitly says so (p_set_manual_address =
-- true), which js/delivery.js only passes from openFixStopDetails ("Edit Details" - an address the
-- staff member actually typed). The "Retry Map" button and the routine auto-geocode that runs when
-- a stop is first created both call this RPC with p_set_manual_address left at its default false,
-- since neither of those is a staff typing a NEW address - they're just (re)geocoding whatever
-- address is already being shown, and must not accidentally freeze out future legitimate Pancake
-- address changes for a stop nobody has actually corrected by hand.
--
-- is_manual_address is added to admin_list_delivery_stops' output so the day-detail table can keep
-- showing the existing "(manually entered)" indicator span accurately even now that shipping_
-- address itself may already BE the manual override (previously that indicator only fired via the
-- isPlaceholderAddress+geocoded_address combination - still kept below for stops created before
-- this migration that have a geocoded_address but no ManualAddress yet).

alter table public."DeliveryStops" add column if not exists "ManualAddress" varchar(1000);

-- ============================================================================
-- admin_update_delivery_stop_geocode gains a trailing p_set_manual_address - dropped by OID first,
-- same reason as the two prior migrations (an added parameter is a distinct overload to Postgres).

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

create or replace function public.admin_update_delivery_stop_geocode(
  p_admin_username text,
  p_admin_password text,
  p_stop_id uuid,
  p_geocoded_address text,
  p_latitude numeric,
  p_longitude numeric,
  p_geocode_status text,
  p_customer_name text default null,
  p_contact_number text default null,
  p_notes text default null,
  p_note_print text default null,
  p_set_manual_address boolean default false
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
      "ManualCustomerName" = coalesce(nullif(trim(p_customer_name), ''), "ManualCustomerName"),
      "ManualContactNumber" = coalesce(nullif(trim(p_contact_number), ''), "ManualContactNumber"),
      "Notes" = coalesce(nullif(trim(p_notes), ''), "Notes"),
      "ManualNotePrint" = coalesce(nullif(trim(p_note_print), ''), "ManualNotePrint"),
      "ManualAddress" = case
        when p_set_manual_address then coalesce(nullif(trim(p_geocoded_address), ''), "ManualAddress")
        else "ManualAddress"
      end
  where "StopID" = p_stop_id;
end;
$$;

grant execute on function public.admin_update_delivery_stop_geocode(text, text, uuid, text, numeric, numeric, text, text, text, text, text, boolean) to anon;

-- ============================================================================
-- admin_list_delivery_stops - shipping_address now prefers ManualAddress; is_manual_address added
-- as a new trailing column (return-shape change, so this needs an explicit drop first, same as the
-- contact_number addition in supabase_delivery_walkin_manual_details.sql).

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
  note_print text,
  contact_number text,
  is_manual_address boolean
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
           o."Status"::text,
           coalesce(nullif(trim(s."ManualAddress"), ''), o."ShippingAddress")::text,
           o."MoneyToCollect", o."Balance", s."Notes"::text,
           s."Latitude", s."Longitude", s."GeocodeStatus"::text, s."GeocodedAddress"::text,
           s."RouteName"::text, s."CreatedBy"::text,
           coalesce(
             nullif(trim(s."ManualNotePrint"), ''),
             nullif(trim(o."NotePrint"::text), ''),
             (select string_agg(nullif(trim(l."Note"::text), ''), '; ' order by l."LineID")
                from public."OnlineOrderLines" l
                where l."OrderID" = o."OrderID" and nullif(trim(l."Note"::text), '') is not null)
           ) as note_print,
           s."ManualContactNumber"::text as contact_number,
           (nullif(trim(s."ManualAddress"), '') is not null) as is_manual_address
    from public."DeliveryStops" s
    join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    join public."DeliveryTrucks" t on t."TruckID" = s."TruckID"
    where s."DeliveryDate" >= p_start_date and s."DeliveryDate" < p_end_date
    order by s."DeliveryDate", s."StopSequence";
end;
$$;

grant execute on function public.admin_list_delivery_stops(text, text, date, date) to anon;

-- ============================================================================
-- admin_get_delivery_receipt - the printed manifest/receipt/invoice reads this directly, so the
-- manual address override has to be applied here too, ahead of the existing blank/"Walkin"
-- fallback (which still covers stops that only have a geocoded_address, from before this
-- migration).

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
  stop_notes text,
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
  v_manual_address text;
  v_manual_customer_name text;
  v_manual_contact_number text;
  v_manual_note_print text;
  v_stop_notes text;
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

  select s."OrderID", s."GeocodedAddress", s."ManualAddress", s."ManualCustomerName", s."ManualContactNumber", s."ManualNotePrint", s."Notes"::text
    into v_order_id, v_geocoded_address, v_manual_address, v_manual_customer_name, v_manual_contact_number, v_manual_note_print, v_stop_notes
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

  -- Manually-entered overrides, per the header comment above - preferred whenever something was
  -- actually typed at assignment time or via "Edit Details".
  v_customer_name := coalesce(nullif(trim(v_manual_customer_name), ''), v_customer_name);
  v_shipping_phone := coalesce(nullif(trim(v_manual_contact_number), ''), v_shipping_phone);
  v_note_print := coalesce(nullif(trim(v_manual_note_print), ''), v_note_print);
  v_shipping_address := coalesce(nullif(trim(v_manual_address), ''), v_shipping_address);

  -- Same manually-entered-address fallback convention as the Delivery day-detail table
  -- (js/delivery.js's isPlaceholderAddress) - covers a stop whose order has no real
  -- ShippingAddress on file, either genuinely blank or Pancake's own "Walkin" placeholder text,
  -- AND that predates this migration (no ManualAddress set, only the older GeocodedAddress cache).
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
    stop_notes := v_stop_notes;
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
    stop_notes := v_stop_notes;
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
