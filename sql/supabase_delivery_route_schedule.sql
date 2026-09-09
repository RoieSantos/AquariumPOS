-- Delivery Setup: a fixed weekly route per day-of-week (e.g. "every Tuesday = GMA Route"),
-- tagged to MULTIPLE Warehouses and/or Vendors - per "can we allow multiple assignment per day
-- like example: -Warehouse -Vendor1 -Vendor2 -Vendor3, this will be fix schedule for that day".
-- Purely informational (shown on the Delivery calendar's weekday header, and snapshotted onto
-- each order once it's scheduled - see admin_create_delivery_stop/admin_move_delivery_stop in
-- supabase_delivery_tables.sql), does NOT restrict which orders can be assigned on that day.
--
-- Three tables:
--   1. public."DeliveryRouteSchedule" - one row per day-of-week (0 = Sunday ... 6 = Saturday,
--      matching Postgres extract(dow)), just the RouteName. Monday (1) is intentionally never
--      insertable here - see admin_upsert_delivery_route_schedule - no truck runs Mondays at all
--      (supabase_delivery_no_monday_and_shipped_lookup.sql).
--   2. public."DeliveryRouteScheduleWarehouses" - zero or more Warehouse tags per day.
--   3. public."DeliveryRouteScheduleVendors" - zero or more Vendor tags per day.
-- Both child tables are fully replaced (delete + reinsert) on every save - "this will be fix
-- schedule for that day" means the saved set IS that day's schedule, not an incremental add.
--
-- No FK constraints on WarehouseID/VendorCode - matches the existing unenforced-reference
-- convention already used for Items.CategoryCode / Items.VendorCode
-- (supabase_warehouses_items_tables.sql / supabase_vendor_tables.sql).
--
-- Run AFTER supabase_warehouses_items_tables.sql and supabase_vendor_tables.sql (both already in
-- the repo) - not a hard dependency (no FKs), just so the Warehouse/Vendor names this joins
-- against already exist. Safe to re-run even if the earlier single-warehouse/single-vendor
-- version of this file was already applied - it drops those two columns if present.

create table if not exists public."DeliveryRouteSchedule" (
    "DayOfWeek" smallint primary key check ("DayOfWeek" between 0 and 6),
    "RouteName" varchar(200) not null,
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

-- Superseded by the child tables below - drop if this file's earlier single-tag version already
-- ran on this project.
alter table public."DeliveryRouteSchedule" drop column if exists "WarehouseID";
alter table public."DeliveryRouteSchedule" drop column if exists "VendorCode";

alter table public."DeliveryRouteSchedule" enable row level security;
revoke all on public."DeliveryRouteSchedule" from anon, authenticated;

create table if not exists public."DeliveryRouteScheduleWarehouses" (
    "DayOfWeek" smallint not null,
    "WarehouseID" varchar(100) not null,
    primary key ("DayOfWeek", "WarehouseID")
);

alter table public."DeliveryRouteScheduleWarehouses" enable row level security;
revoke all on public."DeliveryRouteScheduleWarehouses" from anon, authenticated;

create table if not exists public."DeliveryRouteScheduleVendors" (
    "DayOfWeek" smallint not null,
    "VendorCode" varchar(50) not null,
    primary key ("DayOfWeek", "VendorCode")
);

alter table public."DeliveryRouteScheduleVendors" enable row level security;
revoke all on public."DeliveryRouteScheduleVendors" from anon, authenticated;

drop function if exists public.admin_list_delivery_route_schedule(text, text);

-- Always returns all 7 weekdays (via generate_series), even ones with no route set yet, so
-- Delivery Setup can render a fixed 7-row form instead of an add/remove list. Monday is included
-- in the result (day_name still shown) purely so the UI can render it as a disabled/greyed row
-- labeled "No Delivery" - route_name etc. will always be null for it since row 1 can never be
-- inserted (see admin_upsert_delivery_route_schedule). warehouse_ids/vendor_codes are returned
-- alongside the *_names arrays (same order) so the Delivery Setup multi-selects can restore which
-- options were previously chosen.
create or replace function public.admin_list_delivery_route_schedule(p_admin_username text, p_admin_password text)
returns table(
  day_of_week smallint,
  day_name text,
  route_name text,
  warehouse_ids text[],
  warehouse_names text[],
  vendor_codes text[],
  vendor_names text[],
  updated_by text,
  updated_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      d.dow::smallint,
      (array['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'])[d.dow + 1]::text,
      r."RouteName"::text,
      coalesce(wh.warehouse_ids, array[]::text[]),
      coalesce(wh.warehouse_names, array[]::text[]),
      coalesce(vd.vendor_codes, array[]::text[]),
      coalesce(vd.vendor_names, array[]::text[]),
      r."UpdatedBy"::text,
      r."UpdatedAtUtc"
    from generate_series(0, 6) as d(dow)
    left join public."DeliveryRouteSchedule" r on r."DayOfWeek" = d.dow
    left join (
      select rsw."DayOfWeek",
             array_agg(rsw."WarehouseID"::text order by w."Name") as warehouse_ids,
             array_agg(coalesce(w."Name", rsw."WarehouseID")::text order by w."Name") as warehouse_names
      from public."DeliveryRouteScheduleWarehouses" rsw
      left join public."Warehouses" w on w."ID" = rsw."WarehouseID"
      group by rsw."DayOfWeek"
    ) wh on wh."DayOfWeek" = d.dow
    left join (
      select rsv."DayOfWeek",
             array_agg(rsv."VendorCode"::text order by v."Name") as vendor_codes,
             array_agg(coalesce(v."Name", rsv."VendorCode")::text order by v."Name") as vendor_names
      from public."DeliveryRouteScheduleVendors" rsv
      left join public."Vendors" v on v."VendorCode" = rsv."VendorCode"
      group by rsv."DayOfWeek"
    ) vd on vd."DayOfWeek" = d.dow
    order by d.dow;
end;
$$;

drop function if exists public.admin_upsert_delivery_route_schedule(text, text, smallint, text, text, text);
drop function if exists public.admin_upsert_delivery_route_schedule(text, text, smallint, text, text[], text[]);

-- Fully replaces the day's Warehouse/Vendor tag set on every call (delete + reinsert) -
-- "this will be fix schedule for that day" means the arrays passed in ARE that day's schedule,
-- not an incremental add. Clears (deletes) the day's row entirely when p_route_name is blank and
-- both arrays are empty, so an emptied-out day goes back to "no fixed route" rather than
-- lingering as a blank row. Route Name alone is still required to save a route (Warehouses/
-- Vendors are optional tags on top of it).
create or replace function public.admin_upsert_delivery_route_schedule(
  p_admin_username text,
  p_admin_password text,
  p_day_of_week smallint,
  p_route_name text,
  p_warehouse_ids text[] default null,
  p_vendor_codes text[] default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_route_name text := nullif(trim(p_route_name), '');
  v_warehouse_ids text[] := coalesce(array_remove(p_warehouse_ids, null), array[]::text[]);
  v_vendor_codes text[] := coalesce(array_remove(p_vendor_codes, null), array[]::text[]);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text; return;
  end if;

  if p_day_of_week is null or p_day_of_week not between 0 and 6 then
    return query select false, 'Invalid day of week.'::text; return;
  end if;

  if p_day_of_week = 1 then
    return query select false, 'Mondays have no delivery route - no truck runs that day.'::text; return;
  end if;

  if v_route_name is null and array_length(v_warehouse_ids, 1) is null and array_length(v_vendor_codes, 1) is null then
    delete from public."DeliveryRouteSchedule" where "DayOfWeek" = p_day_of_week;
    delete from public."DeliveryRouteScheduleWarehouses" where "DayOfWeek" = p_day_of_week;
    delete from public."DeliveryRouteScheduleVendors" where "DayOfWeek" = p_day_of_week;
    return query select true, 'Route cleared.'::text; return;
  end if;

  if v_route_name is null then
    return query select false, 'Route Name is required.'::text; return;
  end if;

  insert into public."DeliveryRouteSchedule" ("DayOfWeek", "RouteName", "UpdatedBy", "UpdatedAtUtc")
  values (p_day_of_week, v_route_name, p_admin_username, now())
  on conflict ("DayOfWeek") do update
    set "RouteName" = excluded."RouteName",
        "UpdatedBy" = excluded."UpdatedBy",
        "UpdatedAtUtc" = excluded."UpdatedAtUtc";

  delete from public."DeliveryRouteScheduleWarehouses" where "DayOfWeek" = p_day_of_week;
  if array_length(v_warehouse_ids, 1) is not null then
    insert into public."DeliveryRouteScheduleWarehouses" ("DayOfWeek", "WarehouseID")
    select p_day_of_week, w from unnest(v_warehouse_ids) as w;
  end if;

  delete from public."DeliveryRouteScheduleVendors" where "DayOfWeek" = p_day_of_week;
  if array_length(v_vendor_codes, 1) is not null then
    insert into public."DeliveryRouteScheduleVendors" ("DayOfWeek", "VendorCode")
    select p_day_of_week, v from unnest(v_vendor_codes) as v;
  end if;

  return query select true, 'Route saved.'::text;
end;
$$;

drop function if exists public.staff_get_delivery_route_schedule(text, text);

-- Read-only, any-staff version for the Delivery calendar itself (open to all staff, same tier as
-- the rest of delivery.js) - just the days that actually have a route set, so the client can
-- label the weekday header without exposing the full admin CRUD surface. warehouse_ids/
-- vendor_codes are returned alongside their *_names (same order) so delivery.js can
-- cross-reference into its own staff_search_warehouses/staff_search_vendors lookups for
-- Address/Latitude/Longitude - see supabase_warehouse_address_geocode.sql and
-- supabase_vendor_address_geocode.sql.
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

grant execute on function public.admin_list_delivery_route_schedule(text, text) to anon;
grant execute on function public.admin_upsert_delivery_route_schedule(text, text, smallint, text, text[], text[]) to anon;
grant execute on function public.staff_get_delivery_route_schedule(text, text) to anon;
