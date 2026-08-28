-- Lets Delivery plot a fixed-route Vendor as an origin marker on a day's map, same as Warehouses
-- already do (supabase_warehouse_address_geocode.sql). Per "once the Vendor has been assigned in
-- the Delivery Setup can you flow the address too in the maps".
--
-- Vendors already has an Address column (supabase_vendor_tables.sql) - this just adds the
-- geocode cache, populated lazily from the Delivery page itself (any active staff) the first
-- time it's needed, same staleness pattern (GeocodedAddress vs current Address) as Warehouses/
-- DeliveryStops.

alter table public."Vendors" add column if not exists "Latitude" numeric(10, 7);
alter table public."Vendors" add column if not exists "Longitude" numeric(10, 7);
alter table public."Vendors" add column if not exists "GeocodeStatus" varchar(20);
alter table public."Vendors" add column if not exists "GeocodedAddress" varchar(500);
alter table public."Vendors" add column if not exists "GeocodedAtUtc" timestamptz;

create or replace function public.admin_update_vendor_geocode(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
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

  update public."Vendors"
  set "GeocodedAddress" = p_geocoded_address,
      "Latitude" = p_latitude,
      "Longitude" = p_longitude,
      "GeocodeStatus" = p_geocode_status,
      "GeocodedAtUtc" = now()
  where "VendorCode" = p_vendor_code;
end;
$$;

drop function if exists public.staff_search_vendors(text, text, text, int);

-- Per "can you include the details too on the delivery view? so the user can see the address /
-- contacts and other details" - widened to also return ContactPerson/Phone/Email (already on
-- Vendors, supabase_vendor_tables.sql) so the Delivery calendar's vendor stops (both the weekly
-- recurring Delivery Setup schedule and per-date ad hoc assignments, supabase_delivery_date_
-- vendors.sql) can show more than just a name - see renderDateVendorsSection/fixedRouteRowHtml
-- (docs/js/delivery.js), which already cache this whole row per vendor in vendorByCode.
create or replace function public.staff_search_vendors(p_admin_username text, p_admin_password text, p_search text default null, p_limit int default 50)
returns table(
  vendor_code text,
  name text,
  address text,
  contact_person text,
  phone text,
  email text,
  latitude numeric,
  longitude numeric,
  geocode_status text,
  geocoded_address text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "VendorCode"::text, "Name"::text, "Address"::text, "ContactPerson"::text, "Phone"::text, "Email"::text,
           "Latitude", "Longitude", "GeocodeStatus"::text, "GeocodedAddress"::text
    from public."Vendors"
    where "IsActive" and (p_search is null or trim(p_search) = '' or "Name" ilike '%' || p_search || '%')
    order by "Name"
    limit v_limit;
end;
$$;

-- staff_get_delivery_route_schedule (supabase_delivery_route_schedule.sql) also needs to return
-- vendor_codes now, not just vendor_names, so delivery.js can cross-reference into
-- staff_search_vendors above for each tagged vendor's Address/Latitude/Longitude. Return shape
-- widening needs the explicit drop (Postgres 42P13).
drop function if exists public.staff_get_delivery_route_schedule(text, text);

create or replace function public.staff_get_delivery_route_schedule(p_admin_username text, p_admin_password text)
returns table(
  day_of_week smallint,
  route_name text,
  warehouse_ids text[],
  warehouse_names text[],
  vendor_codes text[],
  vendor_names text[]
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
    select
      r."DayOfWeek",
      r."RouteName"::text,
      coalesce(wh.warehouse_ids, array[]::text[]),
      coalesce(wh.warehouse_names, array[]::text[]),
      coalesce(vd.vendor_codes, array[]::text[]),
      coalesce(vd.vendor_names, array[]::text[])
    from public."DeliveryRouteSchedule" r
    left join (
      select rsw."DayOfWeek",
             array_agg(rsw."WarehouseID"::text order by w."Name") as warehouse_ids,
             array_agg(coalesce(w."Name", rsw."WarehouseID")::text order by w."Name") as warehouse_names
      from public."DeliveryRouteScheduleWarehouses" rsw
      left join public."Warehouses" w on w."ID" = rsw."WarehouseID"
      group by rsw."DayOfWeek"
    ) wh on wh."DayOfWeek" = r."DayOfWeek"
    left join (
      select rsv."DayOfWeek",
             array_agg(rsv."VendorCode"::text order by v."Name") as vendor_codes,
             array_agg(coalesce(v."Name", rsv."VendorCode")::text order by v."Name") as vendor_names
      from public."DeliveryRouteScheduleVendors" rsv
      left join public."Vendors" v on v."VendorCode" = rsv."VendorCode"
      group by rsv."DayOfWeek"
    ) vd on vd."DayOfWeek" = r."DayOfWeek";
end;
$$;

grant execute on function public.admin_update_vendor_geocode(text, text, text, text, numeric, numeric, text) to anon;
grant execute on function public.staff_search_vendors(text, text, text, int) to anon;
grant execute on function public.staff_get_delivery_route_schedule(text, text) to anon;
