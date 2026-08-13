-- Per-line attachments (pictures/files) for Online Order lines, viewed/managed from the
-- WebPortal's "Online Order Lines" drill-down page (online-order-lines.html /
-- js/onlineOrderLines.js). Pancake itself has no concept of these - they're purely a
-- RS Pet Stop-side addition so staff can attach a reference photo/file (e.g. a customer's
-- reference picture, a packing photo, a signed form) to a specific order line.
--
-- online-order-lines.html reads its line items LIVE from Pancake via
-- admin_get_online_order_detail_live() (see supabase_pancake_manual_sync.sql) - there is no
-- local mirror row per line to hang a column off of, and Pancake's own line_id is the only
-- stable key available for a line within an order. So attachments are stored in their own
-- table here, keyed by (OrderID, LineID) as plain text rather than a foreign key, and are
-- joined back in by the client after it fetches the live line items.
--
-- UPLOAD FLOW / TRUST MODEL (mirrors the rest of this portal - see supabase_orders_sync_tables.sql
-- for the same pattern applied to business data instead of files):
--   1. Client calls admin_create_online_order_line_attachment_upload(), which re-verifies the
--      caller's staff username+password (public.is_staff_authorized(), same as every other
--      Online Orders RPC) and then calls the Supabase Storage REST API SERVER-SIDE using the
--      SECRET/service-role key (same key the desktop app uses - see
--      GlobalSettings.TransferHeaderSupabaseAuthorization) to mint a short-lived signed upload
--      token scoped to one exact object path. The browser's anon key is never granted direct
--      write access to this bucket (no anon/authenticated INSERT policy exists on
--      storage.objects for it - see the bucket creation below), so the ONLY way to get write
--      access to a path is to first pass staff re-verification through this function.
--   2. Client uploads the file bytes straight to Supabase Storage using that one-time token
--      (supabaseClient.storage.from(BUCKET).uploadToSignedUrl(path, token, file)).
--   3. Client calls admin_record_online_order_line_attachment() (re-verifies staff again) to
--      persist the (OrderID, LineID, file name, path, public URL) row only once the upload
--      actually succeeded - so a failed/abandoned upload never leaves a phantom row behind.
--
-- The bucket is created PUBLIC (public read, no signed URL needed to view) since these are
-- just line-item reference photos/files, not sensitive customer PII like the rest of this
-- schema - this keeps rendering thumbnails in the portal a plain <img src>. file_size_limit /
-- allowed_mime_types are enforced by Storage itself as a second layer, not just client-side.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'online-order-line-attachments',
  'online-order-line-attachments',
  true,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'application/pdf']
)
on conflict (id) do nothing;

create table if not exists public."OnlineOrderLineAttachments" (
    "AttachmentID" uuid primary key default gen_random_uuid(),
    "OrderID" varchar(100) not null,
    "LineID" varchar(100) not null,
    "FileName" varchar(300),
    "StoragePath" varchar(500) not null,
    "PublicUrl" varchar(1000) not null,
    "UploadedBy" varchar(100),
    "UploadedAtUtc" timestamptz not null default now()
);

alter table public."OnlineOrderLineAttachments" enable row level security;

create index if not exists "IX_OnlineOrderLineAttachments_Order_Line"
  on public."OnlineOrderLineAttachments" ("OrderID", "LineID");

-- Direct table access stays fully blocked by RLS (no policies), same convention as the rest
-- of this portal - only the re-verifying functions below are reachable from the anon key.
revoke all on public."OnlineOrderLineAttachments" from anon, authenticated;

drop function if exists public.admin_list_online_order_line_attachments(text, text, text);

-- Fetches every attachment for an order in one call (all lines at once) so the lines page
-- can render them without an extra round-trip per line.
create or replace function public.admin_list_online_order_line_attachments(p_admin_username text, p_admin_password text, p_order_id text)
returns table(
  attachment_id uuid,
  order_id text,
  line_id text,
  file_name text,
  public_url text,
  uploaded_by text,
  uploaded_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "AttachmentID", "OrderID"::text, "LineID"::text, "FileName"::text, "PublicUrl"::text,
           "UploadedBy"::text, "UploadedAtUtc"
    from public."OnlineOrderLineAttachments"
    where "OrderID" = p_order_id
    order by "UploadedAtUtc" desc;
end;
$$;

drop function if exists public.admin_create_online_order_line_attachment_upload(text, text, text, text, text);

-- Step 1 of the upload flow (see header comment) - re-verifies staff, then mints a one-time
-- signed upload token for a fresh path under this order/line via the Storage REST API,
-- calling it with the service-role key so the anon-key browser client never needs (or gets)
-- direct write access to the bucket.
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
  -- Storage returns {"url": "/object/upload/sign/<bucket>/<path>?token=..."} - pull the token
  -- out of the url if it isn't also given as its own top-level field.
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

drop function if exists public.admin_record_online_order_line_attachment(text, text, text, text, text, text, text);

-- Step 3 of the upload flow - called only after the client's direct-to-storage upload (using
-- the token from admin_create_online_order_line_attachment_upload) already succeeded, so a
-- failed/abandoned upload never leaves a phantom row.
create or replace function public.admin_record_online_order_line_attachment(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_line_id text,
  p_file_name text,
  p_storage_path text,
  p_public_url text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  insert into public."OnlineOrderLineAttachments"
    ("OrderID", "LineID", "FileName", "StoragePath", "PublicUrl", "UploadedBy")
  values (p_order_id, p_line_id, p_file_name, p_storage_path, p_public_url, p_admin_username)
  returning "AttachmentID" into v_id;

  return v_id;
end;
$$;

drop function if exists public.admin_delete_online_order_line_attachment(text, text, uuid);

-- Removes both the storage object (via the service-role key, same trust model as the upload
-- side) and its metadata row. The DB row is still removed even if the storage-side delete call
-- fails/errors, so a Storage hiccup can't leave an attachment stuck showing in the portal.
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

grant execute on function public.admin_list_online_order_line_attachments(text, text, text) to anon;
grant execute on function public.admin_create_online_order_line_attachment_upload(text, text, text, text, text) to anon;
grant execute on function public.admin_record_online_order_line_attachment(text, text, text, text, text, text, text) to anon;
grant execute on function public.admin_delete_online_order_line_attachment(text, text, uuid) to anon;
