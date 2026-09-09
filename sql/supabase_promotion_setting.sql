-- Ongoing promo text shown on Order Now (no login, anonymous customers) - edited from General
-- Setup (super users only). Per direct request: "I want to add a text file for now to be able to
-- show our customers our ongoing promo this would apply on Order Now."
--
-- Single-row table, same shape/access model as public.CompanyInfo (see
-- supabase_company_info_table.sql) rather than a row in public.PortalSettings - PortalSettings
-- stays super-user-gated even for reads (only staff, via a password-checked RPC), but Order Now
-- runs with no session/credentials at all, so this needs a genuinely public read path. None of
-- this is sensitive (it's meant to be shown to any visitor), so anon SELECT is safe. Writes still
-- go through a super-user-gated RPC only - anon has no INSERT/UPDATE grant.

create table if not exists public."PromotionSettings" (
  "Id" smallint primary key default 1 check ("Id" = 1),
  "PromoText" text,
  "IsActive" boolean not null default false,
  "UpdatedBy" varchar(100),
  "UpdatedAtUtc" timestamptz not null default now()
);

alter table public."PromotionSettings" enable row level security;

drop policy if exists "Public read" on public."PromotionSettings";
create policy "Public read" on public."PromotionSettings"
  for select to anon, authenticated using (true);

-- No insert/update/delete policy for anon/authenticated - writes only via the RPC below.
revoke insert, update, delete on public."PromotionSettings" from anon, authenticated;

drop function if exists public.admin_upsert_promotion_setting(text, text, text, boolean);

create or replace function public.admin_upsert_promotion_setting(
  p_admin_username text,
  p_admin_password text,
  p_promo_text text,
  p_is_active boolean
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

  insert into public."PromotionSettings" ("Id", "PromoText", "IsActive", "UpdatedBy", "UpdatedAtUtc")
  values (1, p_promo_text, coalesce(p_is_active, false), p_admin_username, now())
  on conflict ("Id") do update set
    "PromoText" = excluded."PromoText",
    "IsActive" = excluded."IsActive",
    "UpdatedBy" = excluded."UpdatedBy",
    "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

grant execute on function public.admin_upsert_promotion_setting(text, text, text, boolean) to anon;
