-- Mandatory proof photo on Production Done and Release / Mark Shipped - per "can we mandatory ask them
-- for picture once they clicked Production done? same goes to release/ship".
--
-- Run AFTER supabase_online_order_status_photo.sql (bucket, OnlineOrderStatusPhotos, upload RPC).
-- Safe to re-run.
--
-- The portal (js/onlineOrders.js confirmWithPhoto) won't let the action go through without a photo:
-- it uploads it with admin_create_online_order_status_photo_upload (same bucket as Send Photo), then
-- records it here. Proof photos are NOT sent to the customer - they live in the same
-- OnlineOrderStatusPhotos table with SentToCustomer = null, so the order card's Photos part shows them
-- next to the customer photos. p_ref_id is the Online Order ID, or the Production Order no. / Advance
-- Order no. for those cards (no join to OnlineOrders, so any of the three works).

drop function if exists public.staff_record_online_order_proof_photo(text, text, text, text, text, text);

create or replace function public.staff_record_online_order_proof_photo(
  p_admin_username text,
  p_admin_password text,
  p_ref_id text,
  p_label text,
  p_photo_url text,
  p_photo_storage_path text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if coalesce(trim(p_ref_id), '') = '' or coalesce(trim(p_photo_url), '') = '' then
    raise exception 'Order and photo are required.';
  end if;

  insert into public."OnlineOrderStatusPhotos" ("OrderID", "Status", "StoragePath", "PublicUrl", "SentToCustomer", "SendError", "UploadedBy")
  values (trim(p_ref_id), left(coalesce(nullif(trim(p_label), ''), 'Proof photo'), 50),
          coalesce(p_photo_storage_path, ''), p_photo_url, null, null, p_admin_username);
end;
$$;

grant execute on function public.staff_record_online_order_proof_photo(text, text, text, text, text, text) to anon;

-- Retention: customer photos still go after 30 days; proof photos (SentToCustomer is null) are kept
-- 180 days so a "was it really finished / complete when it left?" question can still be answered.
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
    return;
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  for v_row in
    select "PhotoID", "StoragePath"
    from public."OnlineOrderStatusPhotos"
    where "UploadedAtUtc" < now() - case when "SentToCustomer" is null then interval '180 days' else interval '30 days' end
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
      null;
    end;

    delete from public."OnlineOrderStatusPhotos" where "PhotoID" = v_row."PhotoID";
  end loop;
end;
$$;
