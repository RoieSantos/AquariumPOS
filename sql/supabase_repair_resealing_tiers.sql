-- Scales Resealing/Leak Repair pricing by tank size instead of one flat fee for any size, per
-- direct follow-up: "can you calculate the reseal.. what is the best figure?" -> "yes, scale with
-- size" + "no [cost data], just suggest something reasonable". These are a STARTING POINT, not a
-- verified cost calculation - I don't have RS Pet Stop's real silicone/labor costs, so these are a
-- defensible-but-generic industry-style progression (~1.5x per size jump) anchored on the existing
-- P500 default as the smallest tier. Meant to be sanity-checked and adjusted on the Pricing Setup
-- page, not treated as final.
--
-- Extends RepairPricingSetup (supabase_repair_pricing_setup.sql) additively - "ResealingFlatFee"
-- (already live, already defaults to 500) becomes the <=20 gallon tier's fee, so nothing already
-- saved there is lost; four new columns cover the larger tiers. Still a single fixed-row settings
-- table (Id=1), not a separate tier-rows table, since the breakpoints themselves (20/50/100/150
-- gallons) are fixed in this business rule, not something staff need to add/remove rows for - only
-- the FEES per tier are editable.
--
-- Run this AFTER supabase_repair_pricing_setup.sql, in the Supabase SQL Editor.

alter table public."RepairPricingSetup"
  add column if not exists "ResealingMediumFee" numeric(18, 2) not null default 800;
alter table public."RepairPricingSetup"
  add column if not exists "ResealingLargeFee" numeric(18, 2) not null default 1200;
alter table public."RepairPricingSetup"
  add column if not exists "ResealingXlFee" numeric(18, 2) not null default 1800;
alter table public."RepairPricingSetup"
  add column if not exists "ResealingMonsterFee" numeric(18, 2) not null default 2500;

comment on column public."RepairPricingSetup"."ResealingFlatFee" is 'Resealing/Leak Repair fee for tanks up to 20 gallons (estimated from L x W x H).';
comment on column public."RepairPricingSetup"."ResealingMediumFee" is 'Resealing/Leak Repair fee for tanks 21-50 gallons.';
comment on column public."RepairPricingSetup"."ResealingLargeFee" is 'Resealing/Leak Repair fee for tanks 51-100 gallons.';
comment on column public."RepairPricingSetup"."ResealingXlFee" is 'Resealing/Leak Repair fee for tanks 101-150 gallons.';
comment on column public."RepairPricingSetup"."ResealingMonsterFee" is 'Resealing/Leak Repair fee for tanks over 150 gallons ("monster" tanks) - a starting point; recommend verifying on-site before confirming, same treatment monster tanks already get for delivery (see docs/help.html''s Lalamove guide).';

-- ---------------------------------------------------------------------------
-- public_get_repair_pricing_setup: re-created with the four new tier columns.
drop function if exists public.public_get_repair_pricing_setup();

create or replace function public.public_get_repair_pricing_setup()
returns table(
  panel_replacement_markup_percent numeric,
  resealing_flat_fee numeric,
  resealing_medium_fee numeric,
  resealing_large_fee numeric,
  resealing_xl_fee numeric,
  resealing_monster_fee numeric
)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select
    "PanelReplacementMarkupPercent",
    "ResealingFlatFee",
    "ResealingMediumFee",
    "ResealingLargeFee",
    "ResealingXlFee",
    "ResealingMonsterFee"
  from public."RepairPricingSetup"
  where "Id" = 1;
$$;

grant execute on function public.public_get_repair_pricing_setup() to anon;

-- ---------------------------------------------------------------------------
-- admin_upsert_repair_pricing_setup: re-created accepting all six values at once (same "save
-- everything on this page in one call" pattern the page's other sections already use).
drop function if exists public.admin_upsert_repair_pricing_setup(text, text, numeric, numeric);
drop function if exists public.admin_upsert_repair_pricing_setup(text, text, numeric, numeric, numeric, numeric, numeric);

create or replace function public.admin_upsert_repair_pricing_setup(
  p_admin_username text,
  p_admin_password text,
  p_panel_replacement_markup_percent numeric,
  p_resealing_flat_fee numeric,
  p_resealing_medium_fee numeric,
  p_resealing_large_fee numeric,
  p_resealing_xl_fee numeric,
  p_resealing_monster_fee numeric
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

  if p_panel_replacement_markup_percent is null or p_panel_replacement_markup_percent < 0 then
    raise exception 'Panel replacement markup must be zero or more.';
  end if;
  if p_resealing_flat_fee is null or p_resealing_flat_fee < 0
    or p_resealing_medium_fee is null or p_resealing_medium_fee < 0
    or p_resealing_large_fee is null or p_resealing_large_fee < 0
    or p_resealing_xl_fee is null or p_resealing_xl_fee < 0
    or p_resealing_monster_fee is null or p_resealing_monster_fee < 0
  then
    raise exception 'Every resealing tier fee must be zero or more.';
  end if;

  update public."RepairPricingSetup"
  set "PanelReplacementMarkupPercent" = p_panel_replacement_markup_percent,
      "ResealingFlatFee" = p_resealing_flat_fee,
      "ResealingMediumFee" = p_resealing_medium_fee,
      "ResealingLargeFee" = p_resealing_large_fee,
      "ResealingXlFee" = p_resealing_xl_fee,
      "ResealingMonsterFee" = p_resealing_monster_fee,
      "UpdatedAtUtc" = now(),
      "UpdatedBy" = p_admin_username
  where "Id" = 1;
end;
$$;

grant execute on function public.admin_upsert_repair_pricing_setup(text, text, numeric, numeric, numeric, numeric, numeric, numeric) to anon;
