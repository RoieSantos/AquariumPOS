-- Alice builds Purchase Orders from Portal Chat - per "can I teach Alice to build PO? I'll send what
-- I want to buy then we will create a PO against it" (2026-11-23). Who: super users + anyone with
-- Purchase Order access. Photos: yes (supplier price list / handwritten list). Cost: the item's last
-- cost (Items."Cost", which posting a PO writes back - supabase_item_cost_and_po_line_cost.sql).
--
-- The PO tools themselves live in supabase/functions/portal-chat-alice-reply/po-tools.ts and call
-- the SAME staff_* RPCs the Purchase Orders page uses (staff_search_vendors, staff_search_items,
-- staff_create_purchase_order, ...) with the chatting staff member's own credentials, so the PO is
-- created by them. This file only adds:
--   1. Photo attachments on Portal Chat messages (ChatMessages.AttachmentUrl / AttachmentPath) and
--      a public 'portal-chat-photos' bucket + signed-upload RPC (same pattern as Livestock Losses).
--      Public because Claude fetches the image by URL; paths carry a random uuid so they can't be
--      guessed.
--   2. staff_can_use_alice_po - the server-side "may this person have Alice create POs" check.
--      Mirrors canOpenPortalPage(session, 'purchase-orders.html') in docs/js/auth.js: super user, or
--      any account with a portal permission that isn't locked into Delivery Team / Online Order
--      Staff / Store Manager (those three don't get the Purchase Orders page).
--
-- Safe to re-run.

-- ============================================================================
-- 1. Photo attachments on Portal Chat messages
-- ============================================================================

alter table public."ChatMessages" add column if not exists "AttachmentUrl" varchar(1000);
alter table public."ChatMessages" add column if not exists "AttachmentPath" varchar(500);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('portal-chat-photos', 'portal-chat-photos', true, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop function if exists public.staff_create_portal_chat_photo_upload(text, text, text);

create or replace function public.staff_create_portal_chat_photo_upload(
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
  v_bucket text := 'portal-chat-photos';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_safe_name text;
  v_path text;
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

  v_safe_name := regexp_replace(coalesce(nullif(trim(p_file_name), ''), 'photo.jpg'), '[^A-Za-z0-9._-]+', '_', 'g');
  v_path := to_char(now() at time zone 'utc', 'YYYYMMDD') || '/' || replace(gen_random_uuid()::text, '-', '') || '_' || v_safe_name;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select * into v_response from extensions.http((
    'POST',
    v_base_url || '/storage/v1/object/upload/sign/' || v_bucket || '/' || v_path,
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

grant execute on function public.staff_create_portal_chat_photo_upload(text, text, text) to anon;

-- ============================================================================
-- 2. Who may have Alice create Purchase Orders
-- ============================================================================

drop function if exists public.staff_can_use_alice_po(text, text);

create or replace function public.staff_can_use_alice_po(
  p_admin_username text,
  p_admin_password text
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  u public."StaffUsers"%rowtype;
  v_roles text[];
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return false;
  end if;

  select * into u from public."StaffUsers" where "Username" = p_admin_username and coalesce("IsActive", true);
  if not found then
    return false;
  end if;

  if coalesce(u."SuperUser", false) then
    return true;
  end if;

  -- Locked-down roles with no Purchase Orders page.
  if coalesce(u."DeliveryTeam", false) or coalesce(u."OnlineOrderStaff", false) or coalesce(u."StoreManager", false) then
    return false;
  end if;

  v_roles := coalesce(u."StaffRoles"::text[], array[]::text[]);

  -- Needs at least one real portal permission (a plain account or a maker-only account gets no PO page).
  return coalesce(u."SalesUser", false) or coalesce(u."PayrollOfficer", false) or coalesce(u."SerialAdmin", false)
      or coalesce(u."ProductionMember", false) or coalesce(u."ConversationsStaff", false)
      or 'ProductionManager' = any(v_roles) or 'CatalogEditor' = any(v_roles);
end;
$$;

-- Only the Edge Function (service role) calls this; not exposed to the browser.
revoke execute on function public.staff_can_use_alice_po(text, text) from public, anon, authenticated;
grant execute on function public.staff_can_use_alice_po(text, text) to service_role;
