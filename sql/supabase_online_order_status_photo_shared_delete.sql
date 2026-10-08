-- Send Photo can now re-send a photo the order already has (proof / sent photo or a line attachment
-- image - js/onlineOrders.js handleSendPhotoClick). Each send logs its own OnlineOrderStatusPhotos
-- row, so one image can now sit behind several rows (the re-sent ones carry the same PublicUrl and a
-- blank StoragePath).
--
-- Replaces admin_delete_online_order_status_photo (supabase_online_order_status_photo.sql) so
-- removing one of those rows only deletes the Storage file when nothing else still shows it:
--   * blank StoragePath (a re-sent row) -> row only, never touches Storage;
--   * another row with the same StoragePath or PublicUrl -> row only.
-- Otherwise unchanged. Run AFTER supabase_online_order_status_photo.sql. Safe to re-run.

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
  v_public_url text;
  v_response extensions.http_response;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "StoragePath", "PublicUrl" into v_storage_path, v_public_url
  from public."OnlineOrderStatusPhotos"
  where "PhotoID" = p_photo_id;

  if not found then
    return;
  end if;

  if coalesce(trim(v_storage_path), '') <> ''
     and not exists (
       select 1 from public."OnlineOrderStatusPhotos" o
       where o."PhotoID" <> p_photo_id
         and (o."StoragePath" = v_storage_path or o."PublicUrl" = v_public_url)
     ) then
    select decrypted_secret into v_service_role_key
    from vault.decrypted_secrets
    where name = 'supabase_service_role_key'
    limit 1;

    if v_service_role_key is null or trim(v_service_role_key) = '' then
      raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
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
  end if;

  delete from public."OnlineOrderStatusPhotos" where "PhotoID" = p_photo_id;
end;
$$;

grant execute on function public.admin_delete_online_order_status_photo(text, text, uuid) to anon;
