-- ONE-TIME manual setup - run this in the Supabase SQL editor with the placeholder below replaced
-- by your actual Supabase secret/service-role key (Project Settings -> API -> Secret keys).
--
-- DO NOT commit this file with a real key filled in - paste the real value directly into the SQL
-- editor, run it there, then leave this file in the repo with the placeholder intact. This is
-- what supabase_fix_storage_signed_upload_key.sql / supabase_online_order_line_attachments.sql /
-- supabase_portal_logo_upload.sql now read via Supabase Vault (vault.decrypted_secrets) instead
-- of a hardcoded literal - GitHub's push protection blocks any commit containing a live Supabase
-- secret key, and a hardcoded value would just get re-leaked the next time one of those files
-- changes anyway.
--
-- Uses Supabase Vault (not a plain "ALTER DATABASE ... SET" custom setting) because Supabase's
-- hosted SQL editor role does not have permission to alter database-level parameters
-- ("ERROR: 42501: permission denied to set parameter") - Vault is the supported, purpose-built
-- mechanism for exactly this on Supabase, and works from a normal SQL editor session.
--
-- Safe to re-run: creates the secret the first time, updates it in place on every later run - so
-- rotating this key later is just re-running this same script with the new value.
create extension if not exists supabase_vault cascade;

do $$
declare
  v_id uuid;
  v_secret_value text := '<PASTE_YOUR_SUPABASE_SECRET_KEY_HERE>';
begin
  select id into v_id from vault.secrets where name = 'supabase_service_role_key';

  if v_id is null then
    perform vault.create_secret(
      v_secret_value,
      'supabase_service_role_key',
      'Service role key for internal Supabase Storage API calls made from SQL functions (see supabase_fix_storage_signed_upload_key.sql).'
    );
  else
    perform vault.update_secret(v_id, v_secret_value);
  end if;
end;
$$;
