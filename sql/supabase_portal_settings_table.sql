-- General, portal-managed key/value settings (e.g. third-party API keys like the Google Maps
-- key used by delivery.html) - edited from the "General Setup" WebPortal page instead of
-- hand-editing js/config.js and redeploying. See general-setup.html / js/generalSetup.js.
--
-- Most rows are super-user-only (viewed/edited only through admin_list_portal_settings /
-- admin_upsert_portal_setting / admin_delete_portal_setting, all gated by is_admin_authorized).
-- A setting only becomes readable by regular staff pages (e.g. delivery.js needs the Maps key in
-- every staff member's browser) if it's explicitly flagged IsPublicToStaff = true AND fetched
-- through the narrow admin_get_public_portal_setting RPC below - everything else in this table
-- stays behind the super-user gate even though it's a flat key/value store.

create table if not exists public."PortalSettings" (
    "SettingKey" varchar(100) primary key,
    "SettingValue" text,
    "Description" varchar(500),
    "IsPublicToStaff" boolean not null default false,
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

alter table public."PortalSettings" enable row level security;
revoke all on public."PortalSettings" from anon, authenticated;

insert into public."PortalSettings" ("SettingKey", "SettingValue", "Description", "IsPublicToStaff")
select 'GOOGLE_MAPS_API_KEY', '', 'Google Maps JavaScript API + Geocoding API key used by the Delivery page map.', true
where not exists (select 1 from public."PortalSettings" where "SettingKey" = 'GOOGLE_MAPS_API_KEY');

comment on table public."PortalSettings" is 'Generic key/value settings managed from the General Setup portal page - not just Google Maps, any future portal-side key/config value.';

drop function if exists public.admin_list_portal_settings(text, text);
drop function if exists public.admin_list_portal_settings(text, text, int, int);

-- p_page/p_page_size (portal-wide pagination): total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
create or replace function public.admin_list_portal_settings(p_admin_username text, p_admin_password text, p_page int default 1, p_page_size int default 50)
returns table(
  setting_key text,
  setting_value text,
  description text,
  is_public_to_staff boolean,
  updated_by text,
  updated_at_utc timestamptz,
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
    select "SettingKey"::text, "SettingValue"::text, "Description"::text, "IsPublicToStaff",
           "UpdatedBy"::text, "UpdatedAtUtc",
           count(*) over()
    from public."PortalSettings"
    order by "SettingKey"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_upsert_portal_setting(text, text, text, text, text, boolean);

create or replace function public.admin_upsert_portal_setting(
  p_admin_username text,
  p_admin_password text,
  p_setting_key text,
  p_setting_value text,
  p_description text default null,
  p_is_public_to_staff boolean default false
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

  if p_setting_key is null or trim(p_setting_key) = '' then
    raise exception 'Setting key is required.';
  end if;

  insert into public."PortalSettings" ("SettingKey", "SettingValue", "Description", "IsPublicToStaff", "UpdatedBy", "UpdatedAtUtc")
  values (p_setting_key, p_setting_value, p_description, coalesce(p_is_public_to_staff, false), p_admin_username, now())
  on conflict ("SettingKey") do update
    set "SettingValue" = excluded."SettingValue",
        "Description" = coalesce(excluded."Description", public."PortalSettings"."Description"),
        "IsPublicToStaff" = excluded."IsPublicToStaff",
        "UpdatedBy" = excluded."UpdatedBy",
        "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

drop function if exists public.admin_delete_portal_setting(text, text, text);

create or replace function public.admin_delete_portal_setting(p_admin_username text, p_admin_password text, p_setting_key text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."PortalSettings" where "SettingKey" = p_setting_key;
end;
$$;

drop function if exists public.admin_get_public_portal_setting(text, text, text);

-- The one non-super-user-only RPC in this file - deliberately narrow: any active staff member
-- (is_staff_authorized, same tier as Delivery itself) can look up a SINGLE named setting, and
-- only gets a value back if that row is explicitly flagged IsPublicToStaff = true. Everything
-- else in PortalSettings stays unreachable from this RPC.
create or replace function public.admin_get_public_portal_setting(p_admin_username text, p_admin_password text, p_setting_key text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_value text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "SettingValue" into v_value
  from public."PortalSettings"
  where "SettingKey" = p_setting_key and "IsPublicToStaff" is true;

  return v_value;
end;
$$;

grant execute on function public.admin_list_portal_settings(text, text, int, int) to anon;
grant execute on function public.admin_upsert_portal_setting(text, text, text, text, text, boolean) to anon;
grant execute on function public.admin_delete_portal_setting(text, text, text) to anon;
grant execute on function public.admin_get_public_portal_setting(text, text, text) to anon;
