-- Company letterhead info (logo + name/Facebook/address/contact/DTI no.) shown on printable
-- pages (Transfer Order print, Delivery Manifest - see js/companyBranding.js), a plain logo on
-- the Login page and Dashboard, and (Login page only) a separate background image. Edited from
-- General Setup (super users only).
--
-- A dedicated single-row table rather than more rows in public."PortalSettings" - unlike that
-- table (which stays super-user-gated even for reads, except through the narrow
-- admin_get_public_portal_setting() RPC), this data is meant to be shown on the Login page,
-- which runs with NO session/credentials at all. So it needs a genuinely public read path - RLS
-- grants anon SELECT directly, no RPC/password re-verification needed to read it. None of these
-- fields are sensitive (they're literally meant to be printed/displayed publicly), so that's safe.
-- Writes still go through a super-user-gated RPC only - anon has no INSERT/UPDATE/DELETE grant.
create table if not exists public."CompanyInfo" (
    "Id" smallint primary key default 1 check ("Id" = 1),
    "LogoUrl" text,
    "BackgroundImageUrl" text,
    "CompanyName" varchar(255),
    "FacebookUrl" varchar(255),
    "Address" varchar(500),
    "ContactNo" varchar(100),
    "DtiNo" varchar(100),
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

-- CompanyInfo may already exist from before "BackgroundImageUrl" was added - add it if missing
-- (no-op otherwise), same pattern used elsewhere in this codebase (e.g. Warehouses."IsActive").
alter table public."CompanyInfo" add column if not exists "BackgroundImageUrl" text;

alter table public."CompanyInfo" enable row level security;

drop policy if exists "Public read" on public."CompanyInfo";
create policy "Public read" on public."CompanyInfo"
    for select to anon, authenticated using (true);

-- No insert/update/delete policy for anon/authenticated - writes only via the RPC below.
revoke insert, update, delete on public."CompanyInfo" from anon, authenticated;

drop function if exists public.admin_upsert_company_info(text, text, text, text, text, text, text, text);
drop function if exists public.admin_upsert_company_info(text, text, text, text, text, text, text, text, text);

create or replace function public.admin_upsert_company_info(
  p_admin_username text,
  p_admin_password text,
  p_logo_url text,
  p_background_image_url text,
  p_company_name text,
  p_facebook_url text,
  p_address text,
  p_contact_no text,
  p_dti_no text
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

  insert into public."CompanyInfo"
    ("Id", "LogoUrl", "BackgroundImageUrl", "CompanyName", "FacebookUrl", "Address", "ContactNo", "DtiNo", "UpdatedBy", "UpdatedAtUtc")
  values
    (1, p_logo_url, p_background_image_url, p_company_name, p_facebook_url, p_address, p_contact_no, p_dti_no, p_admin_username, now())
  on conflict ("Id") do update set
    "LogoUrl" = excluded."LogoUrl",
    "BackgroundImageUrl" = excluded."BackgroundImageUrl",
    "CompanyName" = excluded."CompanyName",
    "FacebookUrl" = excluded."FacebookUrl",
    "Address" = excluded."Address",
    "ContactNo" = excluded."ContactNo",
    "DtiNo" = excluded."DtiNo",
    "UpdatedBy" = excluded."UpdatedBy",
    "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

grant execute on function public.admin_upsert_company_info(text, text, text, text, text, text, text, text, text) to anon;
