-- Media Library - per direct request ("a compilation of images and videos saved so they can resend
-- it to the customer when needed"), mirroring the "Media" icon in Facebook's own Page inbox toolbar.
-- Distinct from a Quick Reply (which pairs a photo with a canned TEXT message under a label) and from
-- an ad-hoc attachment (a one-off file from staff's own device, swept up after 60 days) - this is a
-- plain, growing library of reusable photos/videos with no text attached, that staff browse and pick
-- from (one or several at a time) to drop into the reply box for THIS conversation, same as a Quick
-- Reply's photo would be (see useQuickReply in docs/js/gmaConversations.js) - loaded into the
-- composer for review, never sent instantly.
--
-- Public bucket (not chatbot-attachments) - same reasoning as quick-reply-images: these are
-- staff-curated, reusable items meant to be sent out repeatedly over time, not one-off messages, and
-- Facebook's Send API needs a URL it can fetch with no auth of its own, so a stable public URL avoids
-- signed-URL-expiry ever silently breaking an old library item. 25MB/video mime types match the
-- chatbot-attachments bucket's own video support (supabase_chatbot_attachment_video_support.sql) -
-- Facebook's documented cap for a Send API attachment delivered by URL.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'chatbot-media-library',
  'chatbot-media-library',
  true,
  26214400,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'video/mp4', 'video/quicktime']
)
on conflict (id) do nothing;

create table if not exists public."ChatbotMediaItems" (
    "Id" bigint generated always as identity primary key,
    "MediaType" varchar(10) not null check ("MediaType" in ('image', 'video')),
    "StoragePath" varchar(500) not null,
    "MediaUrl" text not null,
    "FileName" varchar(255),
    "CreatedAtUtc" timestamptz not null default now(),
    "CreatedBy" varchar(100)
);

alter table public."ChatbotMediaItems" enable row level security;
revoke all on public."ChatbotMediaItems" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- admin_create_chatbot_media_upload: signed upload, same pattern as
-- admin_create_quick_reply_image_upload (supabase_chatbot_quick_reply_images.sql) - public bucket, so
-- the browser only ever needs a signed UPLOAD token, no separate signed-READ step afterwards.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_create_chatbot_media_upload(text, text, text);

create or replace function public.admin_create_chatbot_media_upload(
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
  v_bucket text := 'chatbot-media-library';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
  v_ext text;
  v_path text;
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

  v_ext := lower(regexp_replace(coalesce(p_file_name, ''), '^.*\.', ''));
  if v_ext !~ '^[a-z0-9]{1,10}$' then
    v_ext := 'jpg';
  end if;
  v_path := 'media-' || extract(epoch from clock_timestamp())::bigint || '-' || floor(random() * 1000000)::int || '.' || v_ext;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_sign_url := v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || v_path;

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

  storage_path := v_path;
  upload_token := v_token;
  public_url := v_base_url || '/storage/v1/object/public/' || v_bucket || '/' || v_path;
  return next;
end;
$$;

grant execute on function public.admin_create_chatbot_media_upload(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_add_chatbot_media_item / admin_list_chatbot_media_items / admin_delete_chatbot_media_item:
-- record-keeping around the upload above, same shape as the Quick Reply image list. Delete removes
-- the DB row only (same tradeoff already accepted for admin_delete_chatbot_quick_reply_image) - the
-- Storage object is left behind rather than risk a mistaken delete racing a customer's in-flight
-- Send API fetch of it.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_add_chatbot_media_item(text, text, text, text, text, text);

create or replace function public.admin_add_chatbot_media_item(
  p_admin_username text,
  p_admin_password text,
  p_storage_path text,
  p_media_url text,
  p_media_type text,
  p_file_name text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
  v_media_type text := lower(trim(coalesce(p_media_type, '')));
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_storage_path is null or trim(p_storage_path) = '' or p_media_url is null or trim(p_media_url) = '' then
    raise exception 'Storage path/url is required.';
  end if;
  if v_media_type not in ('image', 'video') then
    v_media_type := 'image';
  end if;

  insert into public."ChatbotMediaItems" ("MediaType", "StoragePath", "MediaUrl", "FileName", "CreatedBy")
  values (v_media_type, trim(p_storage_path), trim(p_media_url), nullif(trim(coalesce(p_file_name, '')), ''), p_admin_username)
  returning "Id" into v_id;

  return v_id;
end;
$$;

grant execute on function public.admin_add_chatbot_media_item(text, text, text, text, text, text) to anon;

drop function if exists public.admin_list_chatbot_media_items(text, text);

create or replace function public.admin_list_chatbot_media_items(
  p_admin_username text,
  p_admin_password text
)
returns table(id bigint, media_type text, media_url text, file_name text, created_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select m."Id", m."MediaType"::text, m."MediaUrl"::text, m."FileName"::text, m."CreatedAtUtc"
    from public."ChatbotMediaItems" m
    order by m."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_chatbot_media_items(text, text) to anon;

drop function if exists public.admin_delete_chatbot_media_item(text, text, bigint);

create or replace function public.admin_delete_chatbot_media_item(
  p_admin_username text,
  p_admin_password text,
  p_media_id bigint
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

  delete from public."ChatbotMediaItems" where "Id" = p_media_id;
end;
$$;

grant execute on function public.admin_delete_chatbot_media_item(text, text, bigint) to anon;
