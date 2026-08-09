-- Company logo + Login page background image uploads, edited from General Setup (super users
-- only). The resulting public URLs are saved into public."CompanyInfo"."LogoUrl"/
-- "BackgroundImageUrl" (see supabase_company_info_table.sql) via admin_upsert_company_info(),
-- alongside the rest of the letterhead fields (name/Facebook/address/contact/DTI no.) - see
-- js/companyBranding.js. This file only adds what's needed to get the actual image FILEs into
-- Storage: a public bucket plus signed-upload-token RPCs, mirroring the upload flow in
-- supabase_online_order_line_attachments.sql (see that file's header comment for the full
-- trust-model rationale) but gated by is_admin_authorized instead of is_staff_authorized, since
-- only super users can reach General Setup in the first place.
--
-- Both asset types always upload to the SAME fixed path (logo/company-logo.<ext> or
-- background/login-background.<ext>) with upsert=true on the client upload call, so re-uploading
-- overwrites the old file rather than accumulating one object per upload - there's only ever one
-- current logo and one current background. The caller appends a cache-busting query string to
-- the public URL it saves into CompanyInfo (see generalSetup.js), since the underlying object
-- path never changes and browsers/CDNs would otherwise keep showing a stale cached image after a
-- re-upload.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'portal-assets',
  'portal-assets',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/svg+xml']
)
on conflict (id) do nothing;

-- Bucket may already exist from before the background image feature bumped the size limit
-- (logos alone were capped at 2 MB; background photos need more room) - raise it if needed.
update storage.buckets set file_size_limit = 5242880 where id = 'portal-assets' and file_size_limit < 5242880;

drop function if exists public._create_signed_portal_asset_upload(text);

-- Shared signing logic for both asset types below - not granted to anon, only called from the
-- is_admin_authorized-gated wrapper functions.
create or replace function public._create_signed_portal_asset_upload(p_path text)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'portal-assets';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text := 'sb_secret_reOTA1Ggd4VkoHz3au7j4g_gOKYYpAW';
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_sign_url := v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || p_path;

  select * into v_response from extensions.http((
    'POST',
    v_sign_url,
    array[
      extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
      extensions.http_header('apikey', v_service_role_key)
    ],
    'application/json',
    '{}'
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Could not prepare upload (HTTP %): %', v_response.status, v_response.content;
  end if;

  v_body := v_response.content::jsonb;
  v_token := coalesce(nullif(v_body ->> 'token', ''), nullif(split_part(coalesce(v_body ->> 'url', ''), 'token=', 2), ''));

  if v_token is null or v_token = '' then
    raise exception 'Storage did not return an upload token.';
  end if;

  storage_path := p_path;
  upload_token := v_token;
  public_url := v_base_url || '/storage/v1/object/public/' || v_bucket || '/' || p_path;
  return next;
end;
$$;

drop function if exists public.admin_create_portal_logo_upload(text, text, text);

create or replace function public.admin_create_portal_logo_upload(
  p_admin_username text,
  p_admin_password text,
  p_file_name text
)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ext text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_ext := lower(regexp_replace(coalesce(p_file_name, ''), '^.*\.', ''));
  if v_ext !~ '^[a-z0-9]{1,10}$' then
    v_ext := 'png';
  end if;

  return query select * from public._create_signed_portal_asset_upload('logo/company-logo.' || v_ext);
end;
$$;

drop function if exists public.admin_create_portal_background_upload(text, text, text);

create or replace function public.admin_create_portal_background_upload(
  p_admin_username text,
  p_admin_password text,
  p_file_name text
)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ext text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_ext := lower(regexp_replace(coalesce(p_file_name, ''), '^.*\.', ''));
  if v_ext !~ '^[a-z0-9]{1,10}$' then
    v_ext := 'png';
  end if;

  return query select * from public._create_signed_portal_asset_upload('background/login-background.' || v_ext);
end;
$$;

grant execute on function public.admin_create_portal_logo_upload(text, text, text) to anon;
grant execute on function public.admin_create_portal_background_upload(text, text, text) to anon;
