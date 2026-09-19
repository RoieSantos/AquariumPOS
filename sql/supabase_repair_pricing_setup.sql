-- Configurable settings for the new Repair Calculator (docs/repair-calculator.html) - per "can we
-- implement repair feature?", scoped to a pricing calculator (like Custom Stand/Aquarium
-- Calculator), not a job-tracking module. Two repair types for now:
--   - Panel Replacement: priced from the damaged panel's own area x the SAME live Glass Pricing
--     Setup rate used everywhere else (GlassPricingSetup/public_get_glass_pricing - see
--     supabase_pricing_setup_tables.sql), plus a labor markup percentage configured here.
--   - Resealing / Leak Repair: a flat fee, also configured here (no glass replaced, so it doesn't
--     need the glass-rate table at all).
-- Single fixed-row settings table, same shape as ChatbotAiSettings/ChatbotFollowUpSettings (Id=1),
-- not a per-feature key/value list, since there are only ever these two knobs.
--
-- NOTE: Alice (the AI bot) does NOT know about repairs yet - per direct instruction, this feature
-- is being built in the system first; teaching the bot about it (new compute_repair_quote tool,
-- system prompt updates) is a separate follow-up once this is confirmed working.
--
-- Run this in the Supabase SQL Editor.

create table if not exists public."RepairPricingSetup" (
  "Id" bigint primary key default 1,
  "PanelReplacementMarkupPercent" numeric(6, 2) not null default 20,
  "ResealingFlatFee" numeric(18, 2) not null default 500,
  "UpdatedAtUtc" timestamptz not null default now(),
  "UpdatedBy" text,
  constraint "CK_RepairPricingSetup_SingleRow" check ("Id" = 1)
);

insert into public."RepairPricingSetup" ("Id")
select 1
where not exists (select 1 from public."RepairPricingSetup" where "Id" = 1);

alter table public."RepairPricingSetup" enable row level security;

-- ---------------------------------------------------------------------------
-- public_get_repair_pricing_setup: same "anon-readable settings" tier as public_get_glass_pricing
-- etc. (supabase_pricing_setup_tables.sql) - the calculator needs this to actually price a repair.
drop function if exists public.public_get_repair_pricing_setup();

create or replace function public.public_get_repair_pricing_setup()
returns table(panel_replacement_markup_percent numeric, resealing_flat_fee numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "PanelReplacementMarkupPercent", "ResealingFlatFee"
  from public."RepairPricingSetup"
  where "Id" = 1;
$$;

grant execute on function public.public_get_repair_pricing_setup() to anon;

-- ---------------------------------------------------------------------------
-- admin_upsert_repair_pricing_setup: same is_admin_authorized (super user) gate as the rest of the
-- Pricing Setup page's write RPCs.
drop function if exists public.admin_upsert_repair_pricing_setup(text, text, numeric, numeric);

create or replace function public.admin_upsert_repair_pricing_setup(
  p_admin_username text,
  p_admin_password text,
  p_panel_replacement_markup_percent numeric,
  p_resealing_flat_fee numeric
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
  if p_resealing_flat_fee is null or p_resealing_flat_fee < 0 then
    raise exception 'Resealing flat fee must be zero or more.';
  end if;

  update public."RepairPricingSetup"
  set "PanelReplacementMarkupPercent" = p_panel_replacement_markup_percent,
      "ResealingFlatFee" = p_resealing_flat_fee,
      "UpdatedAtUtc" = now(),
      "UpdatedBy" = p_admin_username
  where "Id" = 1;
end;
$$;

grant execute on function public.admin_upsert_repair_pricing_setup(text, text, numeric, numeric) to anon;
