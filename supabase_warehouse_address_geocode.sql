-- Adds an Address field to Warehouse Setup, and lets Delivery plot that warehouse as an origin
-- marker on a day's map whenever that weekday's fixed route (Delivery Setup) tags it.
-- Per "put on the Address of the warehouse so it can flow on the delivery address / maps".
--
-- Address is edited from Warehouse Setup (super users only). The geocode cache (Latitude/
-- Longitude/GeocodeStatus/GeocodedAddress/GeocodedAtUtc) is populated lazily from the Delivery
-- page itself (any active staff) the first time it's needed - same trust tier and staleness
-- pattern (GeocodedAddress vs current Address) already used for DeliveryStops
-- (supabase_delivery_tables.sql).

alter table public."Warehouses" add column if not exists "Address" varchar(500);
alter table public."Warehouses" add column if not exists "Latitude" numeric(10, 7);
alter table public."Warehouses" add column if not exists "Longitude" numeric(10, 7);
alter table public."Warehouses" add column if not exists "GeocodeStatus" varchar(20);
alter table public."Warehouses" add column if not exists "GeocodedAddress" varchar(500);
alter table public."Warehouses" add column if not exists "GeocodedAtUtc" timestamptz;

-- CREATE OR REPLACE can't change a function's return-row shape (address/geocode_status are new
-- output columns here) - Postgres requires dropping it first (error 42P13).
drop function if exists public.admin_list_warehouses(text, text, int, int);

create or replace function public.admin_list_warehouses(p_admin_username text, p_admin_password text, p_page int default 1, p_page_size int default 50)
returns table(
  id text,
  name text,
  is_production_warehouse boolean,
  is_stock_warehouse boolean,
  is_active boolean,
  sales_target numeric,
  synced_at_utc timestamptz,
  address text,
  geocode_status text,
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
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "ID"::text, "Name"::text, "IsProductionWarehouse", "IsStockWarehouse", "IsActive", "SalesTarget", "SyncedAtUtc",
           "Address"::text, "GeocodeStatus"::text,
           count(*) over()
    from public."Warehouses"
    order by "Name"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

create or replace function public.admin_update_warehouse_address(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
  p_address text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."Warehouses"
  set "Address" = nullif(trim(p_address), '')
  where "ID" = p_warehouse_id;
end;
$$;

create or replace function public.admin_update_warehouse_geocode(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
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

  update public."Warehouses"
  set "GeocodedAddress" = p_geocoded_address,
      "Latitude" = p_latitude,
      "Longitude" = p_longitude,
      "GeocodeStatus" = p_geocode_status,
      "GeocodedAtUtc" = now()
  where "ID" = p_warehouse_id;
end;
$$;

drop function if exists public.staff_search_warehouses(text, text, text, int);

create or replace function public.staff_search_warehouses(p_admin_username text, p_admin_password text, p_search text default null, p_limit int default 50)
returns table(
  id text,
  name text,
  is_production_warehouse boolean,
  is_stock_warehouse boolean,
  address text,
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
    select "ID"::text, "Name"::text, "IsProductionWarehouse", "IsStockWarehouse",
           "Address"::text, "Latitude", "Longitude", "GeocodeStatus"::text, "GeocodedAddress"::text
    from public."Warehouses"
    where "IsActive" and (p_search is null or trim(p_search) = '' or "Name" ilike '%' || p_search || '%')
    order by "Name"
    limit v_limit;
end;
$$;

grant execute on function public.admin_update_warehouse_address(text, text, text, text) to anon;
grant execute on function public.admin_update_warehouse_geocode(text, text, text, text, numeric, numeric, text) to anon;

-- staff_get_delivery_route_schedule (supabase_delivery_route_schedule.sql) also needs to return
-- warehouse_ids now, not just warehouse_names, so delivery.js can cross-reference into
-- staff_search_warehouses above for each tagged warehouse's Address/Latitude/Longitude. Return
-- shape widening needs the explicit drop (Postgres 42P13).
drop function if exists public.staff_get_delivery_route_schedule(text, text);

create or replace function public.staff_get_delivery_route_schedule(p_admin_username text, p_admin_password text)
returns table(
  day_of_week smallint,
  route_name text,
  warehouse_ids text[],
  warehouse_names text[],
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
      select rsv."DayOfWeek", array_agg(coalesce(v."Name", rsv."VendorCode")::text order by v."Name") as vendor_names
      from public."DeliveryRouteScheduleVendors" rsv
      left join public."Vendors" v on v."VendorCode" = rsv."VendorCode"
      group by rsv."DayOfWeek"
    ) vd on vd."DayOfWeek" = r."DayOfWeek";
end;
$$;

grant execute on function public.staff_get_delivery_route_schedule(text, text) to anon;
