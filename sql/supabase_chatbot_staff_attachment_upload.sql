-- Lets staff attach an ad-hoc photo from their own device directly to a reply (not a reusable Quick
-- Reply template, not a product catalog image) - per direct follow-up request for a generic
-- "attachment" feature in docs/gma-conversations.html's reply composer (the paperclip icon).
--
-- Reuses the PRIVATE chatbot-attachments bucket (supabase_chatbot_message_attachments.sql) rather
-- than the public quick-reply-images bucket - these are one-off images tied to a single reply, not a
-- reusable template meant to be sent over and over, so they SHOULD be swept up by the existing
-- 60-day cron_cleanup_old_chatbot_messages retention, same as an inbound customer photo.
--
-- That cron keys cleanup off ChatbotMessages.AttachmentPath - but admin_send_chatbot_message
-- (supabase_chatbot_quick_reply_images.sql) deliberately never sets it, exactly so a Quick Reply's
-- permanent template image in the OTHER bucket never gets swept up by mistake. Redefined once more
-- below with a new p_attachment_path (default null, so every existing Quick Reply/Product List call
-- site - which has no path to give and shouldn't - is unaffected) so THIS feature's images, which do
-- want cleanup, can actually get it.
--
-- Two-step upload flow, since this bucket is private (unlike the public quick-reply-images bucket,
-- which only ever needed a signed UPLOAD):
--   1. admin_create_chatbot_attachment_upload - signed UPLOAD url/token for a fresh path (same
--      pattern as admin_create_quick_reply_image_upload).
--   2. Browser uploads the file directly to Storage using that token.
--   3. admin_get_chatbot_attachment_signed_url - signed READ url (60-day expiry, same window as
--      every other stored attachment - see cron_cleanup_old_chatbot_messages) for that now-uploaded
--      object. THIS is what actually gets sent to the customer (Facebook's Send API needs a URL it
--      can fetch directly with no auth of its own) and stored as ChatbotMessages.AttachmentUrl -
--      alongside the storage_path from step 1, stored as AttachmentPath so cleanup can find it.

drop function if exists public.admin_send_chatbot_message(text, text, text, text, text, text);

create or replace function public.admin_send_chatbot_message(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_message text,
  p_attachment_url text default null,
  p_attachment_type text default null,
  p_attachment_path text default null
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_message_id bigint;
  v_message text := coalesce(trim(p_message), '');
  v_attachment_url text := nullif(trim(coalesce(p_attachment_url, '')), '');
  v_attachment_type text := nullif(trim(coalesce(p_attachment_type, '')), '');
  v_attachment_path text := nullif(trim(coalesce(p_attachment_path, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;
  if v_message = '' and v_attachment_url is null then
    raise exception 'Message is required.';
  end if;

  insert into public."ChatbotMessages" ("Psid", "Role", "Content", "SentByUsername", "AttachmentUrl", "AttachmentType", "AttachmentPath")
  values (
    p_psid,
    'staff',
    case when v_message = '' then '[Photo]' else v_message end,
    p_admin_username,
    v_attachment_url,
    v_attachment_type,
    v_attachment_path
  )
  returning "Id" into v_message_id;

  update public."ChatbotConversations"
  set "LastMessageAtUtc" = now(),
      "LastBotMessageAtUtc" = now(),
      "IsPaused" = true
  where "Psid" = p_psid;

  if not found then
    raise exception 'No conversation found for that Psid.';
  end if;

  return v_message_id;
end;
$$;

grant execute on function public.admin_send_chatbot_message(text, text, text, text, text, text, text) to anon;

drop function if exists public.admin_create_chatbot_attachment_upload(text, text, text);

create or replace function public.admin_create_chatbot_attachment_upload(
  p_admin_username text,
  p_admin_password text,
  p_file_name text
)
returns table(storage_path text, upload_token text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'chatbot-attachments';
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
  v_path := 'staff-' || extract(epoch from clock_timestamp())::bigint || '-' || floor(random() * 1000000)::int || '.' || v_ext;

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
  return next;
end;
$$;

grant execute on function public.admin_create_chatbot_attachment_upload(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_get_chatbot_attachment_signed_url: signed READ url for an object already uploaded via the
-- flow above. 60-day expiry - matches the retention window every other stored ChatbotMessages
-- attachment already uses (see supabase_chatbot_message_attachments.sql).
-- ---------------------------------------------------------------------------
drop function if exists public.admin_get_chatbot_attachment_signed_url(text, text, text);

create or replace function public.admin_get_chatbot_attachment_signed_url(
  p_admin_username text,
  p_admin_password text,
  p_storage_path text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'chatbot-attachments';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_signed_path text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_storage_path is null or trim(p_storage_path) = '' then
    raise exception 'Storage path is required.';
  end if;

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_sign_url := v_base_url || '/storage/v1/object/sign/' || v_bucket || '/' || p_storage_path;

  select * into v_response from extensions.http((
    'POST',
    v_sign_url,
    array[
      extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
      extensions.http_header('apikey', v_service_role_key)
    ],
    'application/json',
    jsonb_build_object('expiresIn', 60 * 24 * 60 * 60)::text
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Could not sign attachment URL (HTTP %): %', v_response.status, left(v_response.content, 300);
  end if;

  v_body := v_response.content::jsonb;
  -- storage-api returns {"signedURL": "/object/sign/<bucket>/<path>?token=..."} - defensively also
  -- try the lowercase-d variant some client libraries normalize to, same "never trust one exact key
  -- spelling" discipline as the upload-token parsing above.
  v_signed_path := coalesce(nullif(v_body ->> 'signedURL', ''), nullif(v_body ->> 'signedUrl', ''));

  if v_signed_path is null or trim(v_signed_path) = '' then
    raise exception 'Storage did not return a signed URL.';
  end if;

  return v_base_url || '/storage/v1' || v_signed_path;
end;
$$;

grant execute on function public.admin_get_chatbot_attachment_signed_url(text, text, text) to anon;
