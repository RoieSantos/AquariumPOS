-- Lets staff attach a photo (typically snapped on their phone's camera) to the "your order is
-- ready" message sent when marking an Online Order "To Ship" - per direct request: staff pack the
-- order, click To Ship on their mobile device, take a picture of the packed order, and have that
-- picture go out to the customer along with the ready notification.
--
-- Reuses the exact same signed-upload trust model as
-- supabase_online_order_line_attachments.sql: the browser's anon key never gets direct write
-- access to the bucket - admin_create_online_order_status_photo_upload() re-verifies staff, then
-- calls the Storage REST API server-side with the service-role key to mint a one-time signed
-- upload token scoped to one exact object path. The browser then uploads the file bytes straight
-- to Storage with that token (supabaseClient.storage.from(BUCKET).uploadToSignedUrl(...)).
--
-- IMPORTANT - the exact Pancake attachment field/shape is UNVERIFIED. There is no public
-- documentation for it that could be confirmed; supabase_online_order_portal_status_update.sql's
-- _send_online_order_status_message sends the photo as a best-effort SECOND API call, after the
-- text message has already gone out successfully - if Pancake rejects the shape being tried there,
-- the text message still sends and the status still changes; only the photo silently fails to
-- attach (reported back to the portal as photo_error). Adjust the payload shape there once the
-- real one is confirmed against a live test.
--
-- Per direct follow-up request: unlike the first cut of this feature, every photo IS now recorded
-- in public."OnlineOrderStatusPhotos" (SentToCustomer/SendError capture whether the attachment
-- attempt above actually worked) so staff can look back at what was sent - see
-- admin_list_online_order_status_photos() below, shown on the Online Order Lines page
-- (docs/online-order-lines.html). The insert itself happens from
-- admin_update_online_order_status() in supabase_online_order_portal_status_update.sql, right
-- after it gets the photo-send outcome back, since that's the one place that already has the
-- admin username, the order id/status, and the send result all in hand.
--
-- Photos aren't kept forever, though - they're only useful for a little while for troubleshooting
-- a delivery/notification issue, not as a permanent archive, so cron_cleanup_old_online_order_
-- status_photos() (bottom of this file) deletes anything older than 30 days, from both Storage and
-- this table.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'online-order-status-photos',
  'online-order-status-photos',
  true,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do nothing;

drop function if exists public.admin_create_online_order_status_photo_upload(text, text, text, text);

create or replace function public.admin_create_online_order_status_photo_upload(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_file_name text
)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'online-order-status-photos';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
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

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  if p_order_id is null or trim(p_order_id) = '' then
    raise exception 'Order ID is required.';
  end if;

  v_safe_name := regexp_replace(coalesce(nullif(trim(p_file_name), ''), 'photo.jpg'), '[^A-Za-z0-9._-]+', '_', 'g');
  v_path := p_order_id || '/' || to_char(now() at time zone 'utc', 'YYYYMMDDHH24MISSMS') || '_' || v_safe_name;

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
    raise exception 'Could not prepare photo upload (HTTP %): %', v_response.status, v_response.content;
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

grant execute on function public.admin_create_online_order_status_photo_upload(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- History - one row per photo actually captured, written by admin_update_online_order_status
-- (see this file's header comment). Direct table access stays fully blocked by RLS (no policies),
-- same convention as the rest of this portal - only the re-verifying functions below are
-- reachable from the anon key.
-- ---------------------------------------------------------------------------

create table if not exists public."OnlineOrderStatusPhotos" (
  "PhotoID" uuid primary key default gen_random_uuid(),
  "OrderID" varchar(100) not null,
  "Status" varchar(50),
  "StoragePath" varchar(500) not null,
  "PublicUrl" varchar(1000) not null,
  "SentToCustomer" boolean,
  "SendError" text,
  "UploadedBy" varchar(100),
  "UploadedAtUtc" timestamptz not null default now()
);

alter table public."OnlineOrderStatusPhotos" enable row level security;

create index if not exists "IX_OnlineOrderStatusPhotos_OrderID" on public."OnlineOrderStatusPhotos" ("OrderID");

revoke all on public."OnlineOrderStatusPhotos" from anon, authenticated;

drop function if exists public.admin_list_online_order_status_photos(text, text, text);

create or replace function public.admin_list_online_order_status_photos(p_admin_username text, p_admin_password text, p_order_id text)
returns table(
  photo_id uuid,
  status text,
  public_url text,
  sent_to_customer boolean,
  send_error text,
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
    select "PhotoID", "Status"::text, "PublicUrl"::text, "SentToCustomer", "SendError",
           "UploadedBy"::text, "UploadedAtUtc"
    from public."OnlineOrderStatusPhotos"
    where "OrderID" = p_order_id
    order by "UploadedAtUtc" desc;
end;
$$;

drop function if exists public.admin_delete_online_order_status_photo(text, text, uuid);

-- Removes both the storage object (via the service-role key, same trust model as the upload side)
-- and its metadata row. The DB row is still removed even if the storage-side delete call fails/
-- errors, so a Storage hiccup can't leave a photo stuck showing in the portal.
create or replace function public.admin_delete_online_order_status_photo(p_admin_username text, p_admin_password text, p_photo_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'online-order-status-photos';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_storage_path text;
  v_response extensions.http_response;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  select "StoragePath" into v_storage_path
  from public."OnlineOrderStatusPhotos"
  where "PhotoID" = p_photo_id;

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

  delete from public."OnlineOrderStatusPhotos" where "PhotoID" = p_photo_id;
end;
$$;

grant execute on function public.admin_list_online_order_status_photos(text, text, text) to anon;
grant execute on function public.admin_delete_online_order_status_photo(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- Retention - daily cleanup of anything older than 30 days, same reasoning/pattern as
-- cron_sync_online_orders_from_pancake etc. (see supabase_pancake_manual_sync.sql). No grant to
-- anon - called directly by pg_cron inside Postgres, never through PostgREST. Adjust the interval
-- below if 30 days turns out to be too short/long for how staff actually use this history.
-- ---------------------------------------------------------------------------

drop function if exists public.cron_cleanup_old_online_order_status_photos();

create or replace function public.cron_cleanup_old_online_order_status_photos()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'online-order-status-photos';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_row record;
begin
  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    return; -- can't reach Storage without it; rows just wait for the next successful run
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  for v_row in
    select "PhotoID", "StoragePath"
    from public."OnlineOrderStatusPhotos"
    where "UploadedAtUtc" < now() - interval '30 days'
  loop
    begin
      perform extensions.http((
        'POST',
        v_base_url || '/storage/v1/object/remove/' || v_bucket,
        array[
          extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
          extensions.http_header('apikey', v_service_role_key)
        ],
        'application/json',
        jsonb_build_object('prefixes', jsonb_build_array(v_row."StoragePath"))::text
      )::extensions.http_request);
    exception when others then
      null; -- storage-side cleanup is best-effort; still remove the metadata row below
    end;

    delete from public."OnlineOrderStatusPhotos" where "PhotoID" = v_row."PhotoID";
  end loop;
end;
$$;

do $$
begin
  perform cron.unschedule('cleanup-old-online-order-status-photos');
exception when others then
  null; -- job didn't exist yet - nothing to unschedule
end;
$$;

select cron.schedule(
  'cleanup-old-online-order-status-photos',
  '0 3 * * *',
  $$select public.cron_cleanup_old_online_order_status_photos();$$
);
