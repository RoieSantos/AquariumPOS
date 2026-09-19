-- Adds "Hole for aquarium" as a configurable, per-item flat price ("make this a setup") - per
-- direct request: "add Hole for aquarium. hole price is 150 each (make this a setup)". Same
-- family/convention as GlassPricingSetup/TubularPricingSetup/StickerPricingSetup
-- (supabase_pricing_setup_tables.sql), just its own tiny table since this is a flat per-item price
-- with no thickness/type tiers - a generic FeatureKey/Price shape so any future flat-rate aquarium
-- extra can reuse this same table instead of a one-off column.
--
-- Divider pricing is NOT stored here - per direct instruction ("Divider fix is glass price you
-- need to calculate the height and width price + 20%"), it's derived live from the aquarium's own
-- already-configured glass price (see custom-aquarium-calculator.js), not its own settable rate.
--
-- Run this AFTER supabase_pricing_setup_tables.sql (same admin auth/RLS conventions).

create table if not exists public."AquariumExtraPricingSetup" (
  "Id" bigint generated always as identity primary key,
  "FeatureKey" text not null unique,
  "Price" numeric(18, 2) not null,
  "UpdatedAtUtc" timestamptz not null default now(),
  "UpdatedBy" text
);

alter table public."AquariumExtraPricingSetup" enable row level security;

insert into public."AquariumExtraPricingSetup" ("FeatureKey", "Price")
select 'Hole', 150.00
where not exists (select 1 from public."AquariumExtraPricingSetup" where "FeatureKey" = 'Hole');

-- ---------------------------------------------------------------------------
-- Public read RPC - no auth, same exposure class as public_get_glass_pricing (just a price list),
-- used by Order Now's Aquarium builder.
-- ---------------------------------------------------------------------------

drop function if exists public.public_get_aquarium_extra_pricing();

create or replace function public.public_get_aquarium_extra_pricing()
returns table(feature_key text, price numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "FeatureKey"::text, "Price"
  from public."AquariumExtraPricingSetup"
  order by "FeatureKey";
$$;

grant execute on function public.public_get_aquarium_extra_pricing() to anon;

-- ---------------------------------------------------------------------------
-- Staff-facing list/upsert RPCs - same admin-only gate (is_admin_authorized/super users) as the
-- other Pricing Setup tables, edited from the same docs/pricing-setup.html page.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_list_aquarium_extra_pricing(text, text);

create or replace function public.admin_list_aquarium_extra_pricing(p_admin_username text, p_admin_password text)
returns table(feature_key text, price numeric, updated_at_utc timestamptz, updated_by text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "FeatureKey"::text, "Price", "UpdatedAtUtc", "UpdatedBy"::text
    from public."AquariumExtraPricingSetup"
    order by "FeatureKey";
end;
$$;

grant execute on function public.admin_list_aquarium_extra_pricing(text, text) to anon;

drop function if exists public.admin_upsert_aquarium_extra_pricing(text, text, text, numeric);

create or replace function public.admin_upsert_aquarium_extra_pricing(
  p_admin_username text,
  p_admin_password text,
  p_feature_key text,
  p_price numeric
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
  if p_feature_key is null or trim(p_feature_key) = '' then
    raise exception 'Feature key is required.';
  end if;
  if p_price is null or p_price < 0 then
    raise exception 'Price must be a non-negative number.';
  end if;

  update public."AquariumExtraPricingSetup"
  set "Price" = p_price, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
  where "FeatureKey" = trim(p_feature_key);

  if not found then
    insert into public."AquariumExtraPricingSetup" ("FeatureKey", "Price", "UpdatedBy")
    values (trim(p_feature_key), p_price, p_admin_username);
  end if;
end;
$$;

grant execute on function public.admin_upsert_aquarium_extra_pricing(text, text, text, numeric) to anon;

revoke all on public."AquariumExtraPricingSetup" from anon, authenticated;
