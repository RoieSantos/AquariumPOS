-- Delivery scheduling: a calendar where staff assign Online Orders to a delivery date on a
-- truck, then view that day's stops on a Google Map (client-side, using the Maps JS API +
-- Geocoding API - see WebPortal/js/delivery.js). The order picker looks up orders NOT YET marked
-- ForDelivery (see admin_list_deliverable_online_orders below) - assigning one to a date is what
-- flips OnlineOrders."ForDelivery" to true (admin_create_delivery_stop), rather than relying on
-- whatever ForDelivery value Pancake itself synced in.
--
-- NOT related to DeliveryTrackingForm.cs (that's inter-warehouse stock transfer tracking, an
-- unrelated desktop-only concept reusing the OnlineOrdersForm grid in a different mode) or the
-- Lalamove settings in GlobalSettings.cs (unused, dead courier-API test scaffolding). This is a
-- fresh concept with its own tables.
--
-- Single truck for v1 - DeliveryTrucks exists as its own table (not a hardcoded name) so a
-- second truck later is a data row, not a schema change. No driver/route/multi-truck UI yet.

create table if not exists public."DeliveryTrucks" (
    "TruckID" uuid primary key default gen_random_uuid(),
    "TruckName" varchar(100) not null,
    "IsActive" boolean not null default true,
    "CreatedAtUtc" timestamptz not null default now()
);

alter table public."DeliveryTrucks" enable row level security;
revoke all on public."DeliveryTrucks" from anon, authenticated;

insert into public."DeliveryTrucks" ("TruckName")
select 'Main Truck'
where not exists (select 1 from public."DeliveryTrucks");

-- One row per (order assigned to a delivery date). Keyed by a surrogate uuid (not
-- (Date, OrderID)) so a stop can move between dates without a delete+reinsert - see
-- admin_move_delivery_stop below. The unique constraint still blocks double-assigning the same
-- order to the same date by accident.
--
-- Geocode results (Latitude/Longitude) are cached HERE, not on OnlineOrders. OnlineOrders is a
-- Pancake-synced mirror table - its GlassThickness/GlassThicknessCheckedAt cache only survives
-- syncs because every upsert call site remembers to exclude those columns from its
-- "on conflict ... do update set" list; one slip anywhere would wipe cached data. DeliveryStops
-- is never touched by any sync, so there's no such risk. GeocodedAddress snapshots the exact
-- address text that was geocoded, so staleness is self-evident if ShippingAddress changes after
-- scheduling (GeocodedAddress <> current shipping_address = "re-geocode" prompt in the UI).
create table if not exists public."DeliveryStops" (
    "StopID" uuid primary key default gen_random_uuid(),
    "OrderID" varchar(100) not null references public."OnlineOrders"("OrderID"),
    "TruckID" uuid not null references public."DeliveryTrucks"("TruckID"),
    "DeliveryDate" date not null,
    "StopSequence" int not null default 0,
    "Notes" varchar(1000),
    "GeocodedAddress" varchar(1000),
    "Latitude" numeric(10, 7),
    "Longitude" numeric(10, 7),
    "GeocodeStatus" varchar(20),
    "GeocodedAtUtc" timestamptz,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now(),
    "RouteName" varchar(200),
    constraint "UQ_DeliveryStops_Order_Date" unique ("OrderID", "DeliveryDate")
);

-- DeliveryStops may already exist from before RouteName was added - add it if missing (no-op
-- otherwise). Snapshot of DeliveryRouteSchedule."RouteName" for that date's day-of-week, taken
-- at the moment the order is scheduled (or moved to a new date) - see admin_create_delivery_stop
-- / admin_move_delivery_stop (supabase_delivery_route_schedule.sql) - so "tag the name" onto the
-- order sticks even if the weekly schedule is edited later. Not synced by Pancake, never touched
-- outside those two RPCs.
alter table public."DeliveryStops" add column if not exists "RouteName" varchar(200);

alter table public."DeliveryStops" enable row level security;
revoke all on public."DeliveryStops" from anon, authenticated;

create index if not exists "IX_DeliveryStops_Date" on public."DeliveryStops" ("DeliveryDate");

comment on table public."DeliveryTrucks" is 'Lookup table of delivery trucks - one row seeded for v1, more can be added later without a schema change.';
comment on table public."DeliveryStops" is 'One row per Online Order assigned to a delivery date/truck. Geocode results are cached here (not on OnlineOrders) since this table is never touched by the Pancake sync.';

-- Every RPC below re-verifies the acting staff member via is_staff_authorized() (any active
-- staff - same tier as admin_list_online_orders, since this reads/writes the same order set),
-- not direct anon table access - RLS stays enabled with no policies on both tables.

drop function if exists public.admin_list_deliverable_online_orders(text, text, text);
drop function if exists public.admin_list_deliverable_online_orders(text, text, text, int, int);

-- Orders eligible to be scheduled: NOT already marked ForDelivery, and status is Confirmed/
-- Printed/To Ship/Shipped only - per "lookup all order that is for delivery = false, then once
-- its being assign can we now do for delivery = true" followed by "only confirmed / printed /
-- To Ship status can be lookedup", later extended to also include Shipped. Once an order is
-- assigned (admin_create_delivery_stop flips
-- ForDelivery to true), it naturally drops out of this list on the next search - it's been
-- handled. LEFT JOIN DeliveryStops is kept even though a ForDelivery-true order won't match the
-- where clause above (harmless no-op today) - it only matters if scheduled_date/stop_id ever need
-- to be surfaced for a row still in this result set.
--
-- p_page/p_page_size (portal-wide pagination): total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
create or replace function public.admin_list_deliverable_online_orders(p_admin_username text, p_admin_password text, p_search text default null, p_page int default 1, p_page_size int default 50)
returns table(
  order_id text,
  customer_name text,
  status text,
  shipping_address text,
  money_to_collect numeric,
  balance numeric,
  estimated_delivery_date date,
  scheduled_date date,
  stop_id uuid,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."OrderID"::text, o."CustomerName"::text, o."Status"::text, o."ShippingAddress"::text,
           o."MoneyToCollect", o."Balance", o."EstimatedDeliveryDate",
           s."DeliveryDate", s."StopID",
           count(*) over()
    from public."OnlineOrders" o
    left join public."DeliveryStops" s on s."OrderID" = o."OrderID"
    where o."ForDelivery" is not true
      and lower(o."Status") in ('confirmed', 'printed', 'to ship', 'shipped')
      and (
        p_search is null or trim(p_search) = ''
        or o."OrderID" ilike '%' || p_search || '%'
        or o."CustomerName" ilike '%' || p_search || '%'
      )
    order by o."Last_Updated_At" desc nulls last
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_list_delivery_stops(text, text, date, date);

-- Powers the calendar - one call per visible month. Joins in the order/truck info the UI needs
-- so it never has to make a second round-trip per stop. Widened to also expose CreatedBy
-- (returned as created_by) so the Stops table can show "Assigned By" instead of Balance.
--
-- note_print: per "can you add the note_print on the stops so the driver can see" - Pancake's own
-- order-level print note (OnlineOrders."NotePrint"), falling back to this order's own line-level
-- Notes (OnlineOrderLines."Note", e.g. a custom aquarium's dimensions/sealant spec) when the
-- order-level one is blank - same fallback logic as admin_get_delivery_receipt's note_print
-- (supabase_delivery_receipt.sql), reused here so the Stops table itself shows the same note a
-- printed Delivery Receipt would, without needing to open the print view first. Deliberately kept
-- distinct from "notes" (DeliveryStops."Notes", a staff-typed scheduling note set when the stop
-- was created) - the two are unrelated fields shown in separate table columns (js/delivery.js).
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
           o."OrderID"::text, o."CustomerName"::text, o."Status"::text, o."ShippingAddress"::text,
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

drop function if exists public.admin_create_delivery_stop(text, text, text, date, uuid, text);

-- p_truck_id defaults to null -> resolves to the one active truck server-side, so the v1 client
-- never has to know a truck table exists (no picker UI yet).
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

  -- No delivery truck runs on Mondays - mirrored client-side in delivery.js so staff see this
  -- before submitting, but enforced here too since this RPC is the actual write path.
  if extract(dow from p_delivery_date) = 1 then
    raise exception 'Mondays are not available for delivery.';
  end if;

  -- Tag the order with that weekday's fixed route (Delivery Setup), snapshotted at scheduling
  -- time so it stays attached to this order even if the weekly schedule changes later.
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

  -- Assigning an order to a delivery date is what marks it ForDelivery = true - the order picker
  -- (admin_list_deliverable_online_orders above) only offers orders that are NOT already flagged,
  -- so this is what removes it from that pool going forward.
  update public."OnlineOrders" set "ForDelivery" = true where "OrderID" = p_order_id;

  return v_id;
end;
$$;

drop function if exists public.admin_update_delivery_stop_geocode(text, text, uuid, text, numeric, numeric, text);

-- Persists a client-side geocode result (browser calls the Google Geocoding API directly, then
-- reports the result back here) against an already-created stop.
create or replace function public.admin_update_delivery_stop_geocode(
  p_admin_username text,
  p_admin_password text,
  p_stop_id uuid,
  p_geocoded_address text,
  p_latitude numeric,
  p_longitude numeric,
  p_geocode_status text
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
      "GeocodedAtUtc" = now()
  where "StopID" = p_stop_id;
end;
$$;

drop function if exists public.admin_move_delivery_stop(text, text, uuid, date);

-- Reassigns a stop to a different date. Geocode columns are left untouched - the address didn't
-- change, no need to re-geocode.
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

  -- Re-snapshot the route tag for the new date's weekday - the old date's route no longer
  -- applies once the order has moved to a different day.
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

drop function if exists public.admin_delete_delivery_stop(text, text, uuid);

-- Unlike every other RPC in this file (is_staff_authorized - Delivery is open to all staff),
-- removing a stop is is_admin_authorized (super users only) - per "if the user is not super user
-- dont allow removing the stops in the delivery". delivery.js also hides the Remove button
-- client-side for non-super users, but this is the actual enforcement.
create or replace function public.admin_delete_delivery_stop(p_admin_username text, p_admin_password text, p_stop_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."DeliveryStops" where "StopID" = p_stop_id returning "OrderID" into v_order_id;

  -- Removing the stop hands the order back to the "not yet assigned" pool (admin_list_
  -- deliverable_online_orders) rather than leaving it permanently flagged ForDelivery = true
  -- with no way to look it up again. Guarded by "not exists another stop" in case an order is
  -- ever legitimately scheduled on more than one date (the unique constraint on DeliveryStops is
  -- per (OrderID, DeliveryDate), not per OrderID alone).
  if v_order_id is not null and not exists (select 1 from public."DeliveryStops" where "OrderID" = v_order_id) then
    update public."OnlineOrders" set "ForDelivery" = false where "OrderID" = v_order_id;
  end if;
end;
$$;

drop function if exists public.admin_list_delivery_trucks(text, text);

-- Not used for a truck-picker in v1 (single truck, no selector) but lets delivery.js display the
-- truck's name without hardcoding it, and makes adding a picker later a UI-only change.
create or replace function public.admin_list_delivery_trucks(p_admin_username text, p_admin_password text)
returns table(truck_id uuid, truck_name text, is_active boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "TruckID", "TruckName"::text, "IsActive" from public."DeliveryTrucks" order by "CreatedAtUtc";
end;
$$;

grant execute on function public.admin_list_deliverable_online_orders(text, text, text, int, int) to anon;
grant execute on function public.admin_list_delivery_stops(text, text, date, date) to anon;
grant execute on function public.admin_create_delivery_stop(text, text, text, date, uuid, text) to anon;
grant execute on function public.admin_update_delivery_stop_geocode(text, text, uuid, text, numeric, numeric, text) to anon;
grant execute on function public.admin_move_delivery_stop(text, text, uuid, date) to anon;
grant execute on function public.admin_delete_delivery_stop(text, text, uuid) to anon;
grant execute on function public.admin_list_delivery_trucks(text, text) to anon;
