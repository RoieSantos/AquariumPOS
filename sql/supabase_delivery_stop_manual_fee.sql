-- Delivery stop: manual Delivery Fee on "Edit Details" - per "can you add a manual delivery fee on the
-- delivery on the edit details".
--
-- New DeliveryStops."ManualDeliveryFee" (portal only, never written to Pancake - same convention as
-- ManualAddress / ManualCustomerName / ManualNotePrint). Once set it wins over the order's own fee
-- (OnlineOrders."DeliveryFee"; advance orders have none) everywhere the stop is shown or printed, and the
-- amount to collect moves with it: Total and Balance = the order's own + (manual fee - order's fee).
-- E.g. advance order balance 3,000 + manual fee 500 -> driver collects 3,500. Type 0 for free delivery.
-- Leaving the box blank keeps whatever was set before (same as the other Edit Details fields).
--
-- Re-creates admin_update_delivery_stop_geocode (supabase_delivery_stop_manual_address.sql, + p_delivery_fee),
-- admin_list_delivery_stops and admin_get_delivery_receipt (supabase_delivery_advance_and_walkin_orders.sql,
-- + the fee), and _notify_delivery_stop_changed (+ "delivery fee changed").
-- Run AFTER supabase_delivery_advance_and_walkin_orders.sql. Safe to re-run. Needs js/delivery.js ?v=advdeliv3.

alter table public."DeliveryStops" add column if not exists "ManualDeliveryFee" numeric(18, 2);

-- ---------------------------------------------------------------------------
-- 1. Edit Details save: + p_delivery_fee (null = leave as is). Dropped by OID first - an added
--    parameter is a separate overload to Postgres.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_update_delivery_stop_geocode'
  loop
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
  p_set_manual_address boolean default false,
  p_delivery_fee numeric default null
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

  if p_delivery_fee is not null and p_delivery_fee < 0 then
    raise exception 'Delivery fee can''t be negative.';
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
      end,
      "ManualDeliveryFee" = coalesce(p_delivery_fee, "ManualDeliveryFee")
  where "StopID" = p_stop_id;
end;
$$;

grant execute on function public.admin_update_delivery_stop_geocode(text, text, uuid, text, numeric, numeric, text, text, text, text, text, boolean, numeric) to anon;

-- ---------------------------------------------------------------------------
-- 2. Stops list: the fee (+ whether it's manual) as two new trailing columns; Total / Balance include it.

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
  is_manual_address boolean,
  source text,
  delivery_fee numeric,          -- this file: manual fee if set, else the order's own
  is_manual_delivery_fee boolean -- this file
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
           coalesce(o."OrderID", 'ADV-' || a."TransactionNo")::text,
           coalesce(nullif(trim(s."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''),
                    o."CustomerName", a."CustomerName")::text,
           case when a."TransactionNo" is not null
                then 'Advance' || coalesce(' - ' || public._advance_order_prod_status(p), '')
                else o."Status" end::text,
           coalesce(nullif(trim(s."ManualAddress"), ''), o."ShippingAddress")::text,
           -- + (manual fee - the order's own fee) once a manual fee is set (this file).
           coalesce(o."MoneyToCollect", a."Balance")
             + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
           coalesce(o."Balance", a."Balance")
             + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
           s."Notes"::text,
           s."Latitude", s."Longitude", s."GeocodeStatus"::text, s."GeocodedAddress"::text,
           s."RouteName"::text, s."CreatedBy"::text,
           coalesce(
             nullif(trim(s."ManualNotePrint"), ''),
             nullif(trim(o."NotePrint"::text), ''),
             (select string_agg(nullif(trim(l."Note"::text), ''), '; ' order by l."LineID")
                from public."OnlineOrderLines" l
                where l."OrderID" = o."OrderID" and nullif(trim(l."Note"::text), '') is not null),
             nullif(trim(a."Order_Description"::text), '')
           ) as note_print,
           coalesce(nullif(trim(s."ManualContactNumber"), ''), nullif(trim(o."WalkinCustomerPhone"), ''))::text as contact_number,
           (nullif(trim(s."ManualAddress"), '') is not null) as is_manual_address,
           case when a."TransactionNo" is not null then 'advance' else 'online' end::text,
           coalesce(s."ManualDeliveryFee", o."DeliveryFee"),
           s."ManualDeliveryFee" is not null
    from public."DeliveryStops" s
    left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
    left join public."AdvanceOrderProduction" p on p."TransactionNo" = s."AdvanceTransactionNo"
    join public."DeliveryTrucks" t on t."TruckID" = s."TruckID"
    where s."DeliveryDate" >= p_start_date and s."DeliveryDate" < p_end_date
      and (o."OrderID" is not null or a."TransactionNo" is not null)
    order by s."DeliveryDate", s."StopSequence";
end;
$$;

grant execute on function public.admin_list_delivery_stops(text, text, date, date) to anon;


-- ---------------------------------------------------------------------------
-- 3. Receipt / invoice / job order / driver detail: manual fee wins; Total / Balance include it.

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
  line_note text,
  source text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text;
  v_advance_no text;
  v_geocoded_address text;
  v_manual_address text;
  v_manual_customer_name text;
  v_manual_contact_number text;
  v_manual_note_print text;
  v_manual_fee numeric;
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

  select s."OrderID", s."AdvanceTransactionNo", s."GeocodedAddress", s."ManualAddress", s."ManualCustomerName", s."ManualContactNumber", s."ManualNotePrint", s."Notes"::text, s."ManualDeliveryFee"
    into v_order_id, v_advance_no, v_geocoded_address, v_manual_address, v_manual_customer_name, v_manual_contact_number, v_manual_note_print, v_stop_notes, v_manual_fee
  from public."DeliveryStops" s
  where s."StopID" = p_stop_id;

  if v_order_id is null and v_advance_no is null then
    raise exception 'Delivery stop not found.';
  end if;

  if v_advance_no is not null then
    select a."Date", a."CustomerName"::text, a."Order_Description"::text, a."UserID"::text,
           coalesce(w."Name", a."Warehouse")::text, w."Address"::text,
           a."Balance", a."Downpayment", a."Discount", a."Balance"
      into v_order_date, v_customer_name, v_note_print, v_confirmed_by,
           v_warehouse_name, v_warehouse_address,
           v_money_to_collect, v_amount_paid, v_discount, v_balance
    from public."AdvanceOrders" a
    left join public."Warehouses" w on lower(trim(w."Name")) = lower(trim(a."Warehouse"))
    where a."TransactionNo" = v_advance_no;
  else
    select o."Date", coalesce(nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName")::text, o."ShippingAddress"::text,
           coalesce(nullif(trim(o."WalkinCustomerPhone"), ''), o."ShippingPhone")::text, o."DeliveryFee", o."NotePrint"::text,
           o."ConfirmedBy"::text, w."Name"::text, w."Address"::text,
           o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance"
      into v_order_date, v_customer_name, v_shipping_address, v_shipping_phone, v_delivery_fee, v_note_print,
           v_confirmed_by, v_warehouse_name, v_warehouse_address,
           v_money_to_collect, v_amount_paid, v_discount, v_balance
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where o."OrderID" = v_order_id;
  end if;

  v_customer_name := coalesce(nullif(trim(v_manual_customer_name), ''), v_customer_name);
  v_shipping_phone := coalesce(nullif(trim(v_manual_contact_number), ''), v_shipping_phone);
  v_note_print := coalesce(nullif(trim(v_manual_note_print), ''), v_note_print);
  v_shipping_address := coalesce(nullif(trim(v_manual_address), ''), v_shipping_address);

  -- Manual delivery fee (this file): replaces the order's fee, and Total / Balance move by the difference.
  if v_manual_fee is not null then
    v_money_to_collect := coalesce(v_money_to_collect, 0) + v_manual_fee - coalesce(v_delivery_fee, 0);
    v_balance := coalesce(v_balance, 0) + v_manual_fee - coalesce(v_delivery_fee, 0);
    v_delivery_fee := v_manual_fee;
  end if;

  v_shipping_address := case
    when v_shipping_address is null or trim(v_shipping_address) = '' or lower(trim(v_shipping_address)) = 'walkin'
      then v_geocoded_address
    else v_shipping_address
  end;

  order_id := coalesce(v_order_id, 'ADV-' || v_advance_no);
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
  source := case when v_advance_no is not null then 'advance' else 'online' end;

  for v_line in
    select l."LineID"::text as line_id, l."Description"::text as description, l."Quantity" as quantity,
           coalesce(l."GrossAmount", l."NetAmount", l."Price" * l."Quantity") as amount,
           nullif(trim(l."Note"::text), '') as note,
           l."LineID"::text as sort_key
    from public."OnlineOrderLines" l
    where v_order_id is not null and l."OrderID" = v_order_id
    union all
    select al."LineNo"::text, al."Description"::text, al."Quantity",
           coalesce(al."GrossAmount", al."NetAmount", al."Price" * al."Quantity"),
           null::text,
           lpad(al."LineNo"::text, 12, '0')
    from public."AdvanceOrderLines" al
    where v_advance_no is not null and al."TransactionNo" = v_advance_no
    order by sort_key
  loop
    v_line_no := v_line_no + 1;
    line_no := v_line_no;
    line_id := v_line.line_id;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    line_amount := v_line.amount;
    line_note := v_line.note;
    return next;
  end loop;

  if v_line_no = 0 then
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


-- ---------------------------------------------------------------------------
-- 4. Delivery-team push: a manual fee change counts as a driver-facing change.

create or replace function public._notify_delivery_stop_changed()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."DeliveryStops" := case when TG_OP = 'DELETE' then OLD else NEW end;
  v_customer text;
  v_label text;
  v_changes text[] := '{}';
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  if v_row."AdvanceTransactionNo" is not null then
    select coalesce(nullif(trim(v_row."ManualCustomerName"), ''), a."CustomerName")
      into v_customer
    from public."AdvanceOrders" a where a."TransactionNo" = v_row."AdvanceTransactionNo";
    v_label := 'Advance Order ' || v_row."AdvanceTransactionNo" || coalesce(' - ' || nullif(trim(v_customer), ''), '');
  else
    select coalesce(nullif(trim(v_row."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName")
      into v_customer
    from public."OnlineOrders" o where o."OrderID" = v_row."OrderID";
    v_label := 'Order ' || coalesce(v_row."OrderID", '-') || coalesce(' - ' || nullif(trim(v_customer), ''), '');
  end if;

  if TG_OP = 'INSERT' then
    perform public._notify_delivery_team('Delivery stop added',
      to_char(NEW."DeliveryDate", 'Dy Mon DD') || ': ' || v_label || coalesce(' (' || nullif(trim(NEW."RouteName"), '') || ')', ''),
      NEW."DeliveryDate");

  elsif TG_OP = 'DELETE' then
    perform public._notify_delivery_team('Delivery stop removed',
      to_char(OLD."DeliveryDate", 'Dy Mon DD') || ': ' || v_label,
      OLD."DeliveryDate");

  elsif NEW."DeliveryDate" is distinct from OLD."DeliveryDate" then
    if greatest(NEW."DeliveryDate", OLD."DeliveryDate") >= v_today then
      perform public._notify_delivery_team('Delivery stop moved',
        v_label || ': ' || to_char(OLD."DeliveryDate", 'Dy Mon DD') || ' -> ' || to_char(NEW."DeliveryDate", 'Dy Mon DD'),
        case when NEW."DeliveryDate" >= v_today then NEW."DeliveryDate" else OLD."DeliveryDate" end);
    end if;

  else
    if NEW."ManualAddress" is distinct from OLD."ManualAddress" then v_changes := array_append(v_changes, 'address'); end if;
    if NEW."Notes" is distinct from OLD."Notes" then v_changes := array_append(v_changes, 'notes'); end if;
    if NEW."ManualNotePrint" is distinct from OLD."ManualNotePrint" then v_changes := array_append(v_changes, 'print note'); end if;
    if NEW."ManualCustomerName" is distinct from OLD."ManualCustomerName"
       or NEW."ManualContactNumber" is distinct from OLD."ManualContactNumber" then v_changes := array_append(v_changes, 'customer details'); end if;
    if NEW."ManualDeliveryFee" is distinct from OLD."ManualDeliveryFee" then v_changes := array_append(v_changes, 'delivery fee'); end if;
    if NEW."StopSequence" is distinct from OLD."StopSequence" then v_changes := array_append(v_changes, 'stop order'); end if;
    if NEW."TruckID" is distinct from OLD."TruckID" then v_changes := array_append(v_changes, 'truck'); end if;

    if array_length(v_changes, 1) is not null then
      perform public._notify_delivery_team('Delivery stop updated',
        to_char(NEW."DeliveryDate", 'Dy Mon DD') || ': ' || v_label || ' - ' || array_to_string(v_changes, ', ') || ' changed',
        NEW."DeliveryDate");
    end if;
  end if;

  return null;
end;
$$;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_update_delivery_stop_geocode', 'admin_list_delivery_stops', 'admin_get_delivery_receipt')
union all
select 'column', 'DeliveryStops.ManualDeliveryFee',
       case when exists (select 1 from information_schema.columns
                         where table_schema = 'public' and table_name = 'DeliveryStops' and column_name = 'ManualDeliveryFee')
            then 'ok' else 'MISSING' end
order by 1, 2;
