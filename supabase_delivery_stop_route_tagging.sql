-- Tags each scheduled order with that weekday's fixed route (Delivery Setup), snapshotted at the
-- moment it's scheduled/moved so it stays attached to the order even if the weekly schedule is
-- edited later. Per "once the order id has been scheduled can you tag the name".
--
-- Run this AFTER supabase_delivery_route_schedule.sql (needs public."DeliveryRouteSchedule" to
-- exist for the snapshot lookup - no FK, just a runtime SELECT).
--
-- This is a complete, standalone redefinition of these three functions (includes the Monday
-- guard from supabase_delivery_no_monday_and_shipped_lookup.sql too) - safe to run whether or
-- not that earlier script has already been applied.

alter table public."DeliveryStops" add column if not exists "RouteName" varchar(200);

-- CREATE OR REPLACE can't change a function's return-row shape (route_name is a new output
-- column here) - Postgres requires dropping it first (error 42P13).
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
  route_name text
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
           o."OrderID"::text, o."CustomerName"::text, o."Status"::text, o."ShippingAddress"::text,
           o."MoneyToCollect", o."Balance", s."Notes"::text,
           s."Latitude", s."Longitude", s."GeocodeStatus"::text, s."GeocodedAddress"::text,
           s."RouteName"::text
    from public."DeliveryStops" s
    join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    join public."DeliveryTrucks" t on t."TruckID" = s."TruckID"
    where s."DeliveryDate" >= p_start_date and s."DeliveryDate" < p_end_date
    order by s."DeliveryDate", s."StopSequence";
end;
$$;

create or replace function public.admin_create_delivery_stop(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_delivery_date date,
  p_truck_id uuid default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_truck_id uuid;
  v_next_sequence int;
  v_id uuid;
  v_route_name text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_order_id is null or trim(p_order_id) = '' or p_delivery_date is null then
    raise exception 'Order ID and delivery date are required.';
  end if;

  if extract(dow from p_delivery_date) = 1 then
    raise exception 'Mondays are not available for delivery.';
  end if;

  select "RouteName" into v_route_name
  from public."DeliveryRouteSchedule"
  where "DayOfWeek" = extract(dow from p_delivery_date);

  v_truck_id := p_truck_id;
  if v_truck_id is null then
    select "TruckID" into v_truck_id from public."DeliveryTrucks" where "IsActive" is true order by "CreatedAtUtc" limit 1;
  end if;

  if v_truck_id is null then
    raise exception 'No active delivery truck is configured.';
  end if;

  select coalesce(max("StopSequence") + 1, 0) into v_next_sequence
  from public."DeliveryStops"
  where "DeliveryDate" = p_delivery_date and "TruckID" = v_truck_id;

  begin
    insert into public."DeliveryStops" ("OrderID", "TruckID", "DeliveryDate", "StopSequence", "Notes", "CreatedBy", "RouteName")
    values (p_order_id, v_truck_id, p_delivery_date, v_next_sequence, p_notes, p_admin_username, v_route_name)
    returning "StopID" into v_id;
  exception when unique_violation then
    raise exception 'This order is already scheduled for that date.';
  end;

  update public."OnlineOrders" set "ForDelivery" = true where "OrderID" = p_order_id;

  return v_id;
end;
$$;

create or replace function public.admin_move_delivery_stop(p_admin_username text, p_admin_password text, p_stop_id uuid, p_new_date date)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_truck_id uuid;
  v_next_sequence int;
  v_route_name text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if extract(dow from p_new_date) = 1 then
    raise exception 'Mondays are not available for delivery.';
  end if;

  select "TruckID" into v_truck_id from public."DeliveryStops" where "StopID" = p_stop_id;
  if not found then
    raise exception 'Delivery stop not found.';
  end if;

  select coalesce(max("StopSequence") + 1, 0) into v_next_sequence
  from public."DeliveryStops"
  where "DeliveryDate" = p_new_date and "TruckID" = v_truck_id and "StopID" <> p_stop_id;

  select "RouteName" into v_route_name
  from public."DeliveryRouteSchedule"
  where "DayOfWeek" = extract(dow from p_new_date);

  begin
    update public."DeliveryStops"
    set "DeliveryDate" = p_new_date, "StopSequence" = v_next_sequence, "RouteName" = v_route_name
    where "StopID" = p_stop_id;
  exception when unique_violation then
    raise exception 'This order is already scheduled for that date.';
  end;
end;
$$;
