-- Video Ad Builder page (video-ad-builder.html), per "can you create me a feature on our portal so we can
-- build it on our own?" - make 15-second Facebook/Instagram Reels ads (1080x1920 MP4) from the portal.
-- The video itself is drawn and encoded in the browser (js/videoAdRenderer.js); the database only keeps
-- the saved ads and their photos/videos.
--
--   VideoAds                           - one row per saved ad. "Config" is the whole ad as JSON (brand,
--                                        accent colour, scenes with their text / style / media URL) - the
--                                        shape is documented at the top of js/videoAdRenderer.js.
--   video-ad-media (storage bucket)    - public bucket for the photos/videos and background songs used in
--                                        ads (50 MB per file).
--   admin_video_ad_list / _save / _delete
--   admin_create_video_ad_media_upload - signed upload token into video-ad-media/<yyyy-mm>/..., the same
--                                        flow as the company logo upload (supabase_portal_logo_upload.sql),
--                                        signed with the Vault service key (supabase_configure_service_role_key.sql).
--
-- Deleting an ad does not delete its uploaded files (another ad may have been duplicated from it and
-- still use them).
--
-- Super users only (is_admin_authorized), like Quick Post.
-- Run AFTER supabase_configure_service_role_key.sql (Vault secret). Safe to re-run.

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------

create table if not exists public."VideoAds" (
  "AdId" bigint generated always as identity primary key,
  "Name" text not null,
  "Config" jsonb not null,
  "CreatedBy" text,
  "CreatedAtUtc" timestamptz not null default now(),
  "UpdatedBy" text,
  "UpdatedAtUtc" timestamptz not null default now()
);

alter table public."VideoAds" enable row level security;

-- ---------------------------------------------------------------------------
-- Storage bucket
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'video-ad-media',
  'video-ad-media',
  true,
  52428800,
  array['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'video/webm', 'video/quicktime',
        'audio/mpeg', 'audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/wav', 'audio/x-wav', 'audio/ogg']
)
on conflict (id) do nothing;

-- Background music uploads (audio/*) were added after the bucket was first created - keep the list current.
update storage.buckets
set allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'video/webm', 'video/quicktime',
                               'audio/mpeg', 'audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/wav', 'audio/x-wav', 'audio/ogg']
where id = 'video-ad-media';

-- ---------------------------------------------------------------------------
-- List / save / delete
-- ---------------------------------------------------------------------------

drop function if exists public.admin_video_ad_list(text, text);

create or replace function public.admin_video_ad_list(p_admin_username text, p_admin_password text)
returns table(ad_id bigint, name text, config jsonb, created_by text, created_at_utc timestamptz,
              updated_by text, updated_at_utc timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
  select a."AdId", a."Name", a."Config", a."CreatedBy", a."CreatedAtUtc", a."UpdatedBy", a."UpdatedAtUtc"
  from public."VideoAds" a
  order by a."UpdatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_video_ad_list(text, text) to anon;

drop function if exists public.admin_video_ad_save(text, text, bigint, text, jsonb);

-- p_ad_id null = new ad. Returns the ad id.
create or replace function public.admin_video_ad_save(
  p_admin_username text,
  p_admin_password text,
  p_ad_id bigint,
  p_name text,
  p_config jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if nullif(trim(p_name), '') is null then
    raise exception 'Give the ad a name.';
  end if;
  if p_config is null or jsonb_typeof(p_config -> 'scenes') <> 'array' then
    raise exception 'The ad has no scenes.';
  end if;

  if p_ad_id is null then
    insert into public."VideoAds" ("Name", "Config", "CreatedBy", "UpdatedBy")
    values (trim(p_name), p_config, p_admin_username, p_admin_username)
    returning "AdId" into v_id;
  else
    update public."VideoAds"
    set "Name" = trim(p_name), "Config" = p_config, "UpdatedBy" = p_admin_username, "UpdatedAtUtc" = now()
    where "AdId" = p_ad_id
    returning "AdId" into v_id;
    if v_id is null then
      raise exception 'That ad no longer exists - it may have been deleted.';
    end if;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_video_ad_save(text, text, bigint, text, jsonb) to anon;

drop function if exists public.admin_video_ad_delete(text, text, bigint);

create or replace function public.admin_video_ad_delete(p_admin_username text, p_admin_password text, p_ad_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  delete from public."VideoAds" where "AdId" = p_ad_id;
end;
$$;

grant execute on function public.admin_video_ad_delete(text, text, bigint) to anon;

-- ---------------------------------------------------------------------------
-- Media upload (signed token; the browser then uploads straight to Storage)
-- ---------------------------------------------------------------------------

drop function if exists public.admin_create_video_ad_media_upload(text, text, text);

create or replace function public.admin_create_video_ad_media_upload(
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
  v_bucket text := 'video-ad-media';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_safe_name text;
  v_path text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  v_safe_name := regexp_replace(coalesce(nullif(trim(p_file_name), ''), 'file'), '[^A-Za-z0-9._-]+', '_', 'g');
  v_path := to_char(now() at time zone 'utc', 'YYYY-MM') || '/'
            || to_char(now() at time zone 'utc', 'YYYYMMDDHH24MISSMS') || '_' || right(v_safe_name, 80);

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select * into v_response from extensions.http((
    'POST',
    v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || v_path,
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

  storage_path := v_path;
  upload_token := v_token;
  public_url := v_base_url || '/storage/v1/object/public/' || v_bucket || '/' || v_path;
  return next;
end;
$$;

grant execute on function public.admin_create_video_ad_media_upload(text, text, text) to anon;
