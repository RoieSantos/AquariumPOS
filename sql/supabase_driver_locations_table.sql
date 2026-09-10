-- Live driver GPS tracking: DriverLocations holds one row per staff member currently sharing
-- their location from the driver Android app (see driver-app/), keyed by Username rather than a
-- separate DriverID since drivers ARE StaffUsers rows flagged "DeliveryTeam" = true (see
-- supabase_staff_users_delivery_team_field.sql) - there's no separate driver identity in this
-- system.
--
-- Read access is intentionally opened to anon/authenticated via a plain RLS policy (unlike every
-- other table in this project, which is locked down to security definer RPCs only) so the portal
-- can subscribe to row changes via Supabase Realtime postgres_changes, which requires the
-- subscribing role to have RLS SELECT visibility. Writes still only happen through
-- driver_update_location/driver_stop_tracking below. This matches the security model already
-- accepted project-wide - see the note at the top of supabase_staff_users_table.sql: the anon key
-- is not treated as a secret boundary in this app.
--
-- Run this in the Supabase SQL Editor, after supabase_staff_users_delivery_team_field.sql.

create table if not exists public."DriverLocations" (
    "Username" varchar(100) primary key references public."StaffUsers"("Username"),
    "Latitude" numeric(10, 7) not null,
    "Longitude" numeric(10, 7) not null,
    "RecordedAtUtc" timestamptz not null,
    "UpdatedAtUtc" timestamptz not null default timezone('utc', now()),
    "IsTracking" boolean not null default true
);

alter table public."DriverLocations" enable row level security;
revoke all on public."DriverLocations" from anon, authenticated;

drop policy if exists "DriverLocations_select_anon" on public."DriverLocations";
create policy "DriverLocations_select_anon" on public."DriverLocations"
    for select
    to anon, authenticated
    using (true);

comment on table public."DriverLocations" is 'One row per DeliveryTeam staff member currently sharing GPS location from the driver Android app. Read-open via RLS policy so the portal can subscribe via Realtime; writes only via driver_update_location/driver_stop_tracking.';

-- Add to the Realtime publication so the portal's postgres_changes subscription (see
-- subscribeToDriverLocations in js/delivery.js) receives row changes. Guarded so re-running this
-- script doesn't error with "relation is already member of publication".
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'DriverLocations'
  ) then
    alter publication supabase_realtime add table public."DriverLocations";
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- driver_update_location: called every N seconds/meters by the driver app while tracking is on.
-- Restricted to DeliveryTeam accounts (not just any staff) since this is specifically the driver
-- role - see supabase_staff_users_delivery_team_field.sql.

drop function if exists public.driver_update_location(text, text, numeric, numeric, timestamptz);

create or replace function public.driver_update_location(
  p_username text,
  p_password text,
  p_latitude numeric,
  p_longitude numeric,
  p_recorded_at_utc timestamptz default timezone('utc', now())
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_is_delivery_team boolean;
begin
  if not public.is_staff_authorized(p_username, p_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select "DeliveryTeam" into v_is_delivery_team from public."StaffUsers" where "Username" = p_username;

  if not coalesce(v_is_delivery_team, false) then
    return query select false, 'Only Delivery Team accounts can share location.'::text;
    return;
  end if;

  if p_latitude is null or p_longitude is null then
    return query select false, 'Latitude/longitude are required.'::text;
    return;
  end if;

  insert into public."DriverLocations" ("Username", "Latitude", "Longitude", "RecordedAtUtc", "UpdatedAtUtc", "IsTracking")
  values (p_username, p_latitude, p_longitude, coalesce(p_recorded_at_utc, timezone('utc', now())), timezone('utc', now()), true)
  on conflict ("Username") do update
    set "Latitude" = excluded."Latitude",
        "Longitude" = excluded."Longitude",
        "RecordedAtUtc" = excluded."RecordedAtUtc",
        "UpdatedAtUtc" = timezone('utc', now()),
        "IsTracking" = true;

  return query select true, 'OK'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- driver_stop_tracking: called when the driver taps Stop (or logs out) in the driver app.

drop function if exists public.driver_stop_tracking(text, text);

create or replace function public.driver_stop_tracking(p_username text, p_password text)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  update public."DriverLocations" set "IsTracking" = false, "UpdatedAtUtc" = timezone('utc', now())
    where "Username" = p_username;

  return query select true, 'OK'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_get_driver_locations: read by the portal's Live Driver Tracking map. Any active staff can
-- view (same tier as the rest of the Delivery page), not just admins.

drop function if exists public.admin_get_driver_locations(text, text);

create or replace function public.admin_get_driver_locations(p_admin_username text, p_admin_password text)
returns table(
  username text,
  display_name text,
  latitude numeric,
  longitude numeric,
  recorded_at_utc timestamptz,
  updated_at_utc timestamptz,
  is_tracking boolean
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
    select dl."Username"::text, su."DisplayName"::text, dl."Latitude", dl."Longitude", dl."RecordedAtUtc", dl."UpdatedAtUtc", dl."IsTracking"
    from public."DriverLocations" dl
    join public."StaffUsers" su on su."Username" = dl."Username"
    order by dl."UpdatedAtUtc" desc;
end;
$$;

grant execute on function public.driver_update_location(text, text, numeric, numeric, timestamptz) to anon;
grant execute on function public.driver_stop_tracking(text, text) to anon;
grant execute on function public.admin_get_driver_locations(text, text) to anon;
