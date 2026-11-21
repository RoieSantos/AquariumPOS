-- Portal asset uploads can overwrite the existing file (x-upsert on the signed upload URL).
-- Run AFTER supabase_fix_storage_signed_upload_key.sql (replaces _create_signed_portal_asset_upload).
-- Safe to re-run.
--
-- Bug: the signed upload URL was created without "x-upsert: true", so Storage baked "no overwrite"
-- into the token - the client's { upsert: true } on uploadToSignedUrl is ignored. Fixed paths
-- (new-arrivals/banner.png, logo/company-logo.<ext>, background/login-background.<ext>) therefore
-- saved fine the first time and failed with "The resource already exists" on every later save.
-- Item images use a random path each time, so they were never affected.

create or replace function public._create_signed_portal_asset_upload(p_path text)
returns table(storage_path text, upload_token text, public_url text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'portal-assets';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_sign_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_token text;
begin
  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is null or trim(v_service_role_key) = '' then
    raise exception 'Vault secret "supabase_service_role_key" is not configured - see supabase_configure_service_role_key.sql.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_sign_url := v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || p_path;

  select * into v_response from extensions.http((
    'POST',
    v_sign_url,
    array[
      extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
      extensions.http_header('apikey', v_service_role_key),
      extensions.http_header('x-upsert', 'true')
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

revoke all on function public._create_signed_portal_asset_upload(text) from public, anon, authenticated;
