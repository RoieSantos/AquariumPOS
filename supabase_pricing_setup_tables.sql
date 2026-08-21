-- Centralizes Glass/Stand-Tubular/Sticker pricing into Supabase - per direct request ("can we
-- centralize everything in the supabase? I want the price to be adjusted in the supabase..
-- Local / Order now / Portal"). Before this, the same numbers were hardcoded/duplicated in THREE
-- places that had already drifted apart:
--   - "Local" (desktop app): GlobalSettings.cs (GetGlassPricePerSqInch/pricePerSqInch*/
--     GetRubberPricePerSqInch) + StandPriceCalculatorForm.cs (TubularRetailRates) + MainForm.cs
--     (Allum TopCover's inline 500m).
--   - "Order Now"/"Portal" (web): docs/WebAquariumCalculator/custom-aquarium-calculator.js's
--     hardcoded DEFAULT_GLASS_PRICES/TUBULAR_RETAIL_RATES/DEFAULT_STICKER_PRICES/etc, plus a
--     STATIC docs/WebAquariumCalculator/glass-pricing.json file some pages fetched instead.
--
-- Concretely: 3mm glass alone was priced 4 different ways (₱70 Local, ₱85 web's Aquarium-builder
-- table, ₱65 the JSON file, ₱70 web's separate sticker-Glass-type table) before this. Per direct
-- confirmation: 3mm glass = ₱85/sqft, 12mm glass = ₱350/sqft going forward - ONE glass price table
-- now, used for both aquarium panels AND the Sticker calculator's "Glass" type (this restores how
-- the desktop app's GetGlassPricePerSqInch always worked - one shared function/table for both -
-- the web port had accidentally forked it into two disagreeing tables).
--
-- Three tables (not one unified table) since Glass/Tubular/Sticker genuinely have different
-- pricing shapes (per-sqft-by-thickness, per-linear-foot-by-size, per-sqft-by-type-with-some-
-- thickness-tiered-and-some-flat) - forcing them into one generic table would just make every
-- query need to filter out irrelevant columns.
--
-- Read RPCs (public_get_*) are anon-grantable - these are just prices, same exposure class as
-- public_list_order_items already returning Items.RetailPrice. Write RPCs (admin_upsert_*) require
-- is_admin_authorized (super users only), same gate as other catalog-editing RPCs like
-- admin_set_item_hide_from_set - pricing is exactly the kind of thing that shouldn't be editable by
-- just any active staff login.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public."GlassPricingSetup" (
  "Id" bigint generated always as identity primary key,
  "Uom" text not null default 'MM',
  "Thickness" text not null,
  "PricePerSqFt" numeric(18, 2) not null,
  "UpdatedAtUtc" timestamptz not null default now(),
  "UpdatedBy" text
);

alter table public."GlassPricingSetup" enable row level security;

create table if not exists public."TubularPricingSetup" (
  "Id" bigint generated always as identity primary key,
  "TubularSize" text not null,
  "PricePerFt" numeric(18, 2) not null,
  "UpdatedAtUtc" timestamptz not null default now(),
  "UpdatedBy" text
);

alter table public."TubularPricingSetup" enable row level security;

-- "Thickness" is null for flat-rate types (Plain/Tiles/Acrylic/Allum TopCover - one price
-- regardless of thickness) and set for Rubber Matting's per-thickness rows (plus a Thickness=null
-- "base" row used as GetRubberPricePerSqInch's own fallback when thickness is blank/unknown).
-- Glass is NOT a StickerType here - the Sticker calculator's "Glass" type reads GlassPricingSetup
-- above instead, per the file header note on unifying the two.
create table if not exists public."StickerPricingSetup" (
  "Id" bigint generated always as identity primary key,
  "StickerType" text not null,
  "Thickness" text,
  "PricePerSqFt" numeric(18, 2) not null,
  "UpdatedAtUtc" timestamptz not null default now(),
  "UpdatedBy" text
);

alter table public."StickerPricingSetup" enable row level security;

-- ---------------------------------------------------------------------------
-- Seed data - only inserted if the table is empty, so re-running this file after staff have
-- already edited prices through the admin page doesn't silently stomp their changes back to
-- these starting values.
-- ---------------------------------------------------------------------------

insert into public."GlassPricingSetup" ("Uom", "Thickness", "PricePerSqFt")
select v.uom, v.thickness, v.price
from (values ('MM', '3', 85.00), ('MM', '6', 185.00), ('MM', '10', 290.00), ('MM', '12', 350.00)) as v(uom, thickness, price)
where not exists (select 1 from public."GlassPricingSetup");

insert into public."TubularPricingSetup" ("TubularSize", "PricePerFt")
select v.size, v.price
from (values ('1x1', 46.00), ('1.5x1.5', 52.00), ('2x2', 95.00)) as v(size, price)
where not exists (select 1 from public."TubularPricingSetup");

insert into public."StickerPricingSetup" ("StickerType", "Thickness", "PricePerSqFt")
select v.sticker_type, v.thickness, v.price
from (values
  ('Plain Sticker', null, 70.00),
  ('Tiles Sticker', null, 90.00),
  ('Acrylic', null, 135.00),
  ('Allum TopCover', null, 500.00),
  ('Rubber Matting', null, 85.00),
  ('Rubber Matting', '3', 26.00),
  ('Rubber Matting', '6', 32.00),
  ('Rubber Matting', '10', 45.00),
  ('Rubber Matting', '12', 60.00)
) as v(sticker_type, thickness, price)
where not exists (select 1 from public."StickerPricingSetup");

-- ---------------------------------------------------------------------------
-- Public read RPCs - no auth, used by Order Now (anon/no-login) and can also be reused by the
-- staff Portal calculators and the desktop app instead of each keeping their own copy.
-- ---------------------------------------------------------------------------

drop function if exists public.public_get_glass_pricing();

create or replace function public.public_get_glass_pricing()
returns table(thickness text, price_per_sqft numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "Thickness"::text, "PricePerSqFt"
  from public."GlassPricingSetup"
  where upper("Uom") = 'MM'
  order by ("Thickness")::int;
$$;

grant execute on function public.public_get_glass_pricing() to anon;

drop function if exists public.public_get_tubular_pricing();

create or replace function public.public_get_tubular_pricing()
returns table(tubular_size text, price_per_ft numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "TubularSize"::text, "PricePerFt"
  from public."TubularPricingSetup"
  order by "PricePerFt";
$$;

grant execute on function public.public_get_tubular_pricing() to anon;

drop function if exists public.public_get_sticker_pricing();

create or replace function public.public_get_sticker_pricing()
returns table(sticker_type text, thickness text, price_per_sqft numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "StickerType"::text, "Thickness"::text, "PricePerSqFt"
  from public."StickerPricingSetup"
  order by "StickerType", "Thickness" nulls first;
$$;

grant execute on function public.public_get_sticker_pricing() to anon;

-- ---------------------------------------------------------------------------
-- Staff-facing list RPCs - same rows as the public ones above, plus the audit columns
-- (UpdatedAtUtc/UpdatedBy) so the admin Pricing Setup page can show "who changed what, when"
-- without exposing staff usernames on the public/anon read RPCs Order Now calls.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_list_glass_pricing(text, text);

create or replace function public.admin_list_glass_pricing(p_admin_username text, p_admin_password text)
returns table(thickness text, price_per_sqft numeric, updated_at_utc timestamptz, updated_by text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "Thickness"::text, "PricePerSqFt", "UpdatedAtUtc", "UpdatedBy"::text
    from public."GlassPricingSetup"
    where upper("Uom") = 'MM'
    order by ("Thickness")::int;
end;
$$;

grant execute on function public.admin_list_glass_pricing(text, text) to anon;

drop function if exists public.admin_list_tubular_pricing(text, text);

create or replace function public.admin_list_tubular_pricing(p_admin_username text, p_admin_password text)
returns table(tubular_size text, price_per_ft numeric, updated_at_utc timestamptz, updated_by text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "TubularSize"::text, "PricePerFt", "UpdatedAtUtc", "UpdatedBy"::text
    from public."TubularPricingSetup"
    order by "PricePerFt";
end;
$$;

grant execute on function public.admin_list_tubular_pricing(text, text) to anon;

drop function if exists public.admin_list_sticker_pricing(text, text);

create or replace function public.admin_list_sticker_pricing(p_admin_username text, p_admin_password text)
returns table(sticker_type text, thickness text, price_per_sqft numeric, updated_at_utc timestamptz, updated_by text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "StickerType"::text, "Thickness"::text, "PricePerSqFt", "UpdatedAtUtc", "UpdatedBy"::text
    from public."StickerPricingSetup"
    order by "StickerType", "Thickness" nulls first;
end;
$$;

grant execute on function public.admin_list_sticker_pricing(text, text) to anon;

-- ---------------------------------------------------------------------------
-- Admin write RPCs - upsert-by-key (update if the row exists, insert if it doesn't), so the
-- admin page can always just "save" a value without needing to know whether it's creating a new
-- tier or editing an existing one.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_upsert_glass_pricing(text, text, text, numeric);

create or replace function public.admin_upsert_glass_pricing(
  p_admin_username text,
  p_admin_password text,
  p_thickness text,
  p_price_per_sqft numeric
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
  if p_thickness is null or trim(p_thickness) = '' then
    raise exception 'Thickness is required.';
  end if;
  if p_price_per_sqft is null or p_price_per_sqft < 0 then
    raise exception 'Price must be a non-negative number.';
  end if;

  update public."GlassPricingSetup"
  set "PricePerSqFt" = p_price_per_sqft, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
  where upper("Uom") = 'MM' and "Thickness" = trim(p_thickness);

  if not found then
    insert into public."GlassPricingSetup" ("Uom", "Thickness", "PricePerSqFt", "UpdatedBy")
    values ('MM', trim(p_thickness), p_price_per_sqft, p_admin_username);
  end if;
end;
$$;

grant execute on function public.admin_upsert_glass_pricing(text, text, text, numeric) to anon;

drop function if exists public.admin_upsert_tubular_pricing(text, text, text, numeric);

create or replace function public.admin_upsert_tubular_pricing(
  p_admin_username text,
  p_admin_password text,
  p_tubular_size text,
  p_price_per_ft numeric
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
  if p_tubular_size is null or trim(p_tubular_size) = '' then
    raise exception 'Tubular size is required.';
  end if;
  if p_price_per_ft is null or p_price_per_ft < 0 then
    raise exception 'Price must be a non-negative number.';
  end if;

  update public."TubularPricingSetup"
  set "PricePerFt" = p_price_per_ft, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
  where "TubularSize" = trim(p_tubular_size);

  if not found then
    insert into public."TubularPricingSetup" ("TubularSize", "PricePerFt", "UpdatedBy")
    values (trim(p_tubular_size), p_price_per_ft, p_admin_username);
  end if;
end;
$$;

grant execute on function public.admin_upsert_tubular_pricing(text, text, text, numeric) to anon;

drop function if exists public.admin_upsert_sticker_pricing(text, text, text, text, numeric);

create or replace function public.admin_upsert_sticker_pricing(
  p_admin_username text,
  p_admin_password text,
  p_sticker_type text,
  p_thickness text,
  p_price_per_sqft numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_thickness text := nullif(trim(coalesce(p_thickness, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_sticker_type is null or trim(p_sticker_type) = '' then
    raise exception 'Sticker type is required.';
  end if;
  if p_price_per_sqft is null or p_price_per_sqft < 0 then
    raise exception 'Price must be a non-negative number.';
  end if;

  update public."StickerPricingSetup"
  set "PricePerSqFt" = p_price_per_sqft, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
  where "StickerType" = trim(p_sticker_type) and coalesce("Thickness", '') = coalesce(v_thickness, '');

  if not found then
    insert into public."StickerPricingSetup" ("StickerType", "Thickness", "PricePerSqFt", "UpdatedBy")
    values (trim(p_sticker_type), v_thickness, p_price_per_sqft, p_admin_username);
  end if;
end;
$$;

grant execute on function public.admin_upsert_sticker_pricing(text, text, text, text, numeric) to anon;

-- ---------------------------------------------------------------------------
-- Lock the tables down directly - all real access goes through the SECURITY DEFINER RPCs above
-- (which run as the function owner and bypass RLS regardless), same pattern as every other table
-- in this project (see e.g. supabase_warehouses_items_tables.sql). Without this, the tables would
-- show as "Unrestricted" in Supabase and be reachable via the auto-generated REST endpoints
-- directly, bypassing the admin auth check inside the upsert RPCs.
-- ---------------------------------------------------------------------------

revoke all on public."GlassPricingSetup" from anon, authenticated;
revoke all on public."TubularPricingSetup" from anon, authenticated;
revoke all on public."StickerPricingSetup" from anon, authenticated;
