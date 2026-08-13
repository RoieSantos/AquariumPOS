-- Fixes "Could not prepare upload (HTTP 400): ... Invalid Compact JWS" errors when uploading
-- Online Order Line attachments (and the same failure on Company Logo / Login Background
-- uploads under General Setup, which share this exact bug).
--
-- ROOT CAUSE: admin_create_online_order_line_attachment_upload / admin_delete_online_order_line_attachment
-- (supabase_online_order_line_attachments.sql) and _create_signed_portal_asset_upload
-- (supabase_portal_logo_upload.sql) call the Supabase Storage REST API directly with a
-- hardcoded secret key (sb_secret_reOTA1Ggd4VkoHz3au7j4g_gOKYYpAW). Per the Supabase dashboard's
-- API Keys screen, that key no longer exists as an active secret key on the project (deleted at
-- some point, never updated in code) - Storage rejected it outright, surfaced as "Invalid
-- Compact JWS". GlobalSettings.TransferHeaderSupabaseAuthorization (desktop app) hardcoded the
-- same stale value and has been updated to match.
--
-- FIX: point these three functions at the newly-generated active secret key. Per GitHub push
-- protection blocking any commit containing a live Supabase secret key (and a hardcoded literal
-- just getting re-leaked the next time this file changes anyway), the key is no longer a literal
-- in these functions at all - each reads it via current_setting('app.settings.
-- supabase_service_role_key', true), a database-level setting configured ONCE, manually, outside
-- git (see supabase_configure_service_role_key.sql - a template, never committed with a real
-- value filled in).

create or replace function public.admin_create_online_order_line_attachment_upload(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_line_id text,
  p_file_name text
)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'online-order-line-attachments';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text := current_setting('app.settings.supabase_service_role_key', true);
  v_safe_name text;
  v_path text;
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'app.settings.supabase_service_role_key is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  if p_order_id is null or trim(p_order_id) = '' or p_line_id is null or trim(p_line_id) = '' then
    raise exception 'Order ID and Line ID are required.';
  end if;

  v_safe_name := regexp_replace(coalesce(nullif(trim(p_file_name), ''), 'file'), '[^A-Za-z0-9._-]+', '_', 'g');
  v_path := p_order_id || '/' || p_line_id || '/' || to_char(now() at time zone 'utc', 'YYYYMMDDHH24MISSMS') || '_' || v_safe_name;

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

create or replace function public.admin_delete_online_order_line_attachment(p_admin_username text, p_admin_password text, p_attachment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'online-order-line-attachments';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text := current_setting('app.settings.supabase_service_role_key', true);
  v_storage_path text;
  v_response extensions.http_response;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'app.settings.supabase_service_role_key is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  select "StoragePath" into v_storage_path
  from public."OnlineOrderLineAttachments"
  where "AttachmentID" = p_attachment_id;

  if not found then
    return;
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

    select * into v_response from extensions.http((
      'POST',
      v_base_url || '/storage/v1/object/remove/' || v_bucket,
      array[
        extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
        extensions.http_header('apikey', v_service_role_key)
      ],
      'application/json',
      jsonb_build_object('prefixes', jsonb_build_array(v_storage_path))::text
    )::extensions.http_request);
  exception when others then
    null; -- storage-side cleanup is best-effort; still remove the metadata row below
  end;

  delete from public."OnlineOrderLineAttachments" where "AttachmentID" = p_attachment_id;
end;
$$;

-- Same bug, same fix, for Company Logo / Login Background uploads (General Setup).
create or replace function public._create_signed_portal_asset_upload(p_path text)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'portal-assets';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text := current_setting('app.settings.supabase_service_role_key', true);
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
begin
  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'app.settings.supabase_service_role_key is not configured - see supabase_configure_service_role_key.sql.';
  end if;

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
