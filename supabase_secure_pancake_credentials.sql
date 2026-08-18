-- Moves the Pancake Cloud (pos.pages.fm) API key out of plaintext SQL source and into Supabase
-- Vault (encrypted at rest in the database), so it's never readable from this - or any other -
-- committed file again. Prior to this, the same literal key was hardcoded directly in 9 SQL files
-- (27 occurrences) across this repo, which is public on GitHub - anyone who read the source (or
-- any bot scraping public repos for exposed API keys, which happens routinely and fast) could
-- read it in plain text. That key must be rotated in the Pancake Partner Portal regardless of
-- anything in this file - moving it to Vault only protects the NEW key going forward, it does not
-- undo the old one already having been exposed.
--
-- SETUP (run once, per project):
--   1. Rotate the Pancake API key in the Pancake Partner Portal - treat the old
--      'e611861d2fc84607bfbbe1428a432447' key as burned, do not reuse it.
--   2. Run this file (supabase_secure_pancake_credentials.sql) - no secret material lives in it,
--      it only creates the functions below.
--   3. Set the new key value using EITHER of these (both end up in the same place - Vault):
--        a) General Setup's "Secure API Keys" panel (docs/general-setup.html) - paste the key,
--           click Save. Nothing is ever read back to the browser afterwards, unlike the plain
--           Settings table further down that page (see admin_list_portal_settings, which DOES
--           send raw setting_value to the browser on every load - fine for things like
--           GOOGLE_MAPS_API_KEY that are meant to be public, wrong for this).
--        b) Directly in the Supabase SQL Editor (do NOT save this command into a file in this
--           repo - that would just recreate the exact same leak with the new key):
--
--             select vault.create_secret('<the new rotated key>', 'PANCAKE_API_KEY', 'Pancake Cloud (pos.pages.fm) API key - shop 1328301944.');
--
-- ROTATING AGAIN LATER: use the General Setup panel again (it upserts), or run
--   select vault.update_secret((select id from vault.secrets where name = 'PANCAKE_API_KEY'), '<new key>');
-- directly in the SQL Editor - no code changes needed, every function using
-- public._pancake_api_key() picks it up immediately.
--
-- SECOND SECRET - PANCAKE_PUBLIC_API_KEY: a DIFFERENT credential from PANCAKE_API_KEY above. This
-- one is the page_access_token used by Pancake's public conversations API
-- (pages.fm/api/public_api/v1/pages/{page_id}/conversations/{conversation_id}/messages) to send a
-- Messenger message into an existing conversation - see public._send_order_confirmation_message()
-- in supabase_automated_orders_tables.sql, which sends the customer an order-confirmation message
-- right after submit_automated_order. It is the SAME value already hardcoded as
-- GlobalSettings.PublicApiKey in the desktop app's source (IntegrationEvents.cs /
-- GlobalSettings.cs) - which means, same as the original PANCAKE_API_KEY, it is already exposed in
-- this public repo's history. Set/rotate it the same way as above, just with name
-- 'PANCAKE_PUBLIC_API_KEY':
--   select vault.create_secret('<the key from GlobalSettings.PublicApiKey, or a freshly rotated one>', 'PANCAKE_PUBLIC_API_KEY', 'Pancake Messenger public_api page_access_token - page 195716644410829.');

create extension if not exists supabase_vault;

drop function if exists public._pancake_api_key();

-- Internal accessor - deliberately NOT granted to anon/authenticated. Every Pancake-calling
-- SECURITY DEFINER function in this codebase calls this instead of embedding the key inline (see
-- supabase_pancake_manual_sync.sql, supabase_transfer_orders_pancake_sync.sql, and others).
create or replace function public._pancake_api_key()
returns text
language sql
security definer
set search_path = public, extensions, vault
stable
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'PANCAKE_API_KEY';
$$;

revoke all on function public._pancake_api_key() from anon, authenticated;

drop function if exists public.admin_set_pancake_api_key(text, text, text);

-- Write-only: takes the new key as input and stores/rotates it in Vault, but NEVER returns a key
-- value to the caller (returns void) - so General Setup's "Secure API Keys" panel can offer a
-- normal Save button without ever pulling the secret back into the browser, same as pasting the
-- vault.create_secret/update_secret commands directly into the SQL Editor. Upserts by name so
-- clicking Save again later (rotating) just updates the same Vault row instead of creating a
-- second one, which would make public._pancake_api_key()'s lookup ambiguous.
create or replace function public.admin_set_pancake_api_key(
  p_admin_username text,
  p_admin_password text,
  p_new_key text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_existing_id uuid;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_new_key is null or trim(p_new_key) = '' then
    raise exception 'API key cannot be empty.';
  end if;

  select id into v_existing_id from vault.secrets where name = 'PANCAKE_API_KEY' limit 1;

  if v_existing_id is not null then
    perform vault.update_secret(v_existing_id, p_new_key);
  else
    perform vault.create_secret(p_new_key, 'PANCAKE_API_KEY', 'Pancake Cloud (pos.pages.fm) API key - shop 1328301944. Set via General Setup.');
  end if;
end;
$$;

drop function if exists public.admin_get_pancake_api_key_status(text, text);

-- Metadata only (whether it's set, and when) - deliberately excludes the key value itself, unlike
-- admin_list_portal_settings. Lets General Setup show "Configured - last updated ..." without
-- ever having the actual secret pass through the browser again after it's first saved.
create or replace function public.admin_get_pancake_api_key_status(
  p_admin_username text,
  p_admin_password text
)
returns table(is_configured boolean, updated_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_updated_at timestamptz;
  v_found boolean := false;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select s.updated_at, true into v_updated_at, v_found
  from vault.secrets s
  where s.name = 'PANCAKE_API_KEY'
  limit 1;

  return query select coalesce(v_found, false), v_updated_at;
end;
$$;

grant execute on function public.admin_set_pancake_api_key(text, text, text) to anon;
grant execute on function public.admin_get_pancake_api_key_status(text, text) to anon;

-- ---------------------------------------------------------------------------
-- PANCAKE_PUBLIC_API_KEY - same shape as PANCAKE_API_KEY above, see the SECOND SECRET comment
-- near the top of this file.
-- ---------------------------------------------------------------------------

drop function if exists public._pancake_public_api_key();

-- Internal accessor - deliberately NOT granted to anon/authenticated. Called only from
-- public._send_order_confirmation_message() (supabase_automated_orders_tables.sql).
create or replace function public._pancake_public_api_key()
returns text
language sql
security definer
set search_path = public, extensions, vault
stable
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'PANCAKE_PUBLIC_API_KEY';
$$;

revoke all on function public._pancake_public_api_key() from anon, authenticated;

drop function if exists public.admin_set_pancake_public_api_key(text, text, text);

-- Write-only, same reasoning as admin_set_pancake_api_key above.
create or replace function public.admin_set_pancake_public_api_key(
  p_admin_username text,
  p_admin_password text,
  p_new_key text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_existing_id uuid;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_new_key is null or trim(p_new_key) = '' then
    raise exception 'API key cannot be empty.';
  end if;

  -- Trimmed server-side too (not just js/generalSetup.js's input.value.trim()) - a stray leading/
  -- trailing character (e.g. a newline picked up from copy-pasting the value out of a source file)
  -- would otherwise be stored verbatim and make Pancake reject an otherwise-valid token with
  -- "Invalid access_token" (error_code 102), with nothing in this file to reveal why.
  select id into v_existing_id from vault.secrets where name = 'PANCAKE_PUBLIC_API_KEY' limit 1;

  if v_existing_id is not null then
    perform vault.update_secret(v_existing_id, trim(p_new_key));
  else
    perform vault.create_secret(trim(p_new_key), 'PANCAKE_PUBLIC_API_KEY', 'Pancake Messenger public_api page_access_token - page 195716644410829. Set via General Setup.');
  end if;
end;
$$;

drop function if exists public.admin_get_pancake_public_api_key_status(text, text);

-- Metadata only, same reasoning as admin_get_pancake_api_key_status above.
create or replace function public.admin_get_pancake_public_api_key_status(
  p_admin_username text,
  p_admin_password text
)
returns table(is_configured boolean, updated_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_updated_at timestamptz;
  v_found boolean := false;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select s.updated_at, true into v_updated_at, v_found
  from vault.secrets s
  where s.name = 'PANCAKE_PUBLIC_API_KEY'
  limit 1;

  return query select coalesce(v_found, false), v_updated_at;
end;
$$;

grant execute on function public.admin_set_pancake_public_api_key(text, text, text) to anon;
grant execute on function public.admin_get_pancake_public_api_key_status(text, text) to anon;
