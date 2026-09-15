-- Lets a Quick Reply (supabase_chatbot_quick_replies.sql) include a photo that sends automatically
-- when chosen - e.g. a price list, storefront photo, or map - per direct follow-up request.

-- Public bucket (not the private chatbot-attachments one used for inbound customer photos) - these
-- are STAFF-curated, reusable TEMPLATE images meant to be sent out repeatedly over time, not
-- one-off messages with a 60-day retention window. Facebook's Send API also needs a URL it can
-- fetch directly with no auth of its own, so a stable public URL avoids any signed-URL-expiry risk
-- silently breaking a quick reply weeks/months after it was set up.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'quick-reply-images',
  'quick-reply-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do nothing;

alter table public."ChatbotQuickReplies" add column if not exists "ImagePath" varchar(500);
alter table public."ChatbotQuickReplies" add column if not exists "ImageUrl" text;

comment on column public."ChatbotQuickReplies"."ImagePath" is 'Storage object path in the quick-reply-images bucket, if this quick reply includes a photo.';
comment on column public."ChatbotQuickReplies"."ImageUrl" is 'Public URL for the photo - sent as an image attachment to the customer (via the Send API) whenever this quick reply is chosen.';

-- ---------------------------------------------------------------------------
-- admin_create_quick_reply_image_upload: signed upload, same pattern as
-- supabase_portal_logo_upload.sql's _create_signed_portal_asset_upload - except each quick reply's
-- image gets its own unique generated path (unlike the logo/background's fixed single path), since
-- there can be many quick replies, each with its own photo.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_create_quick_reply_image_upload(text, text, text);

create or replace function public.admin_create_quick_reply_image_upload(
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
  v_bucket text := 'quick-reply-images';
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
  v_path := 'quickreply-' || extract(epoch from clock_timestamp())::bigint || '-' || floor(random() * 1000000)::int || '.' || v_ext;

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

grant execute on function public.admin_create_quick_reply_image_upload(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_list_chatbot_quick_replies / admin_upsert_chatbot_quick_reply: redefined to surface/accept
-- the image fields. A quick reply now only needs EITHER a message or a photo (or both) - not
-- message text on its own.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_list_chatbot_quick_replies(text, text);

create or replace function public.admin_list_chatbot_quick_replies(
  p_admin_username text,
  p_admin_password text
)
returns table(id bigint, label text, message_text text, image_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select q."Id", q."Label"::text, q."MessageText"::text, q."ImageUrl"::text
    from public."ChatbotQuickReplies" q
    order by q."SortOrder", q."Id";
end;
$$;

grant execute on function public.admin_list_chatbot_quick_replies(text, text) to anon;

drop function if exists public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text);

create or replace function public.admin_upsert_chatbot_quick_reply(
  p_admin_username text,
  p_admin_password text,
  p_id bigint,
  p_label text,
  p_message_text text,
  p_image_path text,
  p_image_url text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
  v_message text := nullif(trim(coalesce(p_message_text, '')), '');
  v_image_path text := nullif(trim(coalesce(p_image_path, '')), '');
  v_image_url text := nullif(trim(coalesce(p_image_url, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_label is null or trim(p_label) = '' then
    raise exception 'Label is required.';
  end if;
  if v_message is null and v_image_url is null then
    raise exception 'Add a message, a photo, or both.';
  end if;

  if p_id is null then
    insert into public."ChatbotQuickReplies" ("Label", "MessageText", "ImagePath", "ImageUrl", "CreatedBy")
    values (trim(p_label), coalesce(v_message, ''), v_image_path, v_image_url, p_admin_username)
    returning "Id" into v_id;
  else
    update public."ChatbotQuickReplies"
    set "Label" = trim(p_label),
        "MessageText" = coalesce(v_message, ''),
        "ImagePath" = v_image_path,
        "ImageUrl" = v_image_url
    where "Id" = p_id;

    if not found then
      raise exception 'Quick reply not found.';
    end if;
    v_id := p_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_send_chatbot_message: redefined once more to optionally store an image attachment
-- alongside a staff reply (see supabase/functions/chatbot-staff-reply's image_url handling). The
-- resulting row is what the GMA inbox thread actually renders - reuses the same AttachmentUrl/
-- AttachmentType columns supabase_chatbot_message_attachments.sql already added for inbound
-- customer photos. Deliberately does NOT set AttachmentPath here - that column is what
-- cron_cleanup_old_chatbot_messages uses to know which Storage object to delete after 60 days, and
-- a Quick Reply's image lives in the SEPARATE, permanent quick-reply-images bucket as a reusable
-- template, not a one-off attachment that should ever be auto-deleted.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_send_chatbot_message(text, text, text, text);

create or replace function public.admin_send_chatbot_message(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_message text,
  p_attachment_url text default null,
  p_attachment_type text default null
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

  insert into public."ChatbotMessages" ("Psid", "Role", "Content", "SentByUsername", "AttachmentUrl", "AttachmentType")
  values (
    p_psid,
    'staff',
    case when v_message = '' then '[Photo]' else v_message end,
    p_admin_username,
    v_attachment_url,
    v_attachment_type
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

grant execute on function public.admin_send_chatbot_message(text, text, text, text, text, text) to anon;
