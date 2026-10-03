-- Store Managers and Production Managers can message GMA Page order customers from Online Orders - per
-- "can you give access to my production manager and store manager please?" (order 106916: To Ship
-- message + the To-Ship Message dialog both failed with "Not authorized.").
--
-- Why it failed: a GMA Page order has no Pancake conversation, so Online Orders sends its To Ship
-- message / photo / Send Message through the chatbot-staff-reply Edge Function, which records it with
-- admin_send_chatbot_message - gated by is_conversations_authorized (Super User or Conversations Access
-- only). Pancake-page orders were never affected (they send with the normal staff check).
--
-- Fix: admin_send_chatbot_message also lets an active Store Manager (StaffUsers.StoreManager) or
-- Production Manager (StaffRoles 'ProductionManager') send - but ONLY to a psid that belongs to an
-- online order (AutomatedOrders.GmaPsid with a PancakeReceiptNo). They still can't open or use GMA
-- Conversations itself (every other GMA Conversations RPC keeps is_conversations_authorized).
--
-- Body otherwise unchanged from supabase_gma_conversations_staff_rpc_access.sql (#25). Run AFTER that
-- file; if it's re-run, run this one again after it. Safe to re-run. No Edge Function redeploy needed.

create or replace function public.is_online_order_messenger_authorized(p_username text, p_password text, p_psid text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_store_manager boolean;
  v_roles text[];
begin
  select "PasswordHash", "IsActive", "StoreManager", "StaffRoles"
    into v_password_hash, v_is_active, v_store_manager, v_roles
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active
     or not (coalesce(v_store_manager, false) or 'ProductionManager' = any(coalesce(v_roles, '{}'))) then
    return false;
  end if;

  -- Only customers with an online order - not any GMA conversation.
  if not exists (
    select 1 from public."AutomatedOrders" ao
    where ao."GmaPsid" = p_psid and nullif(trim(coalesce(ao."PancakeReceiptNo", '')), '') is not null
  ) then
    return false;
  end if;

  return v_password_hash = crypt(p_password, v_password_hash);
end;
$$;

revoke execute on function public.is_online_order_messenger_authorized(text, text, text) from public, anon, authenticated;

create or replace function public.admin_send_chatbot_message(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_message text,
  p_attachment_url text default null,
  p_attachment_type text default null,
  p_attachment_path text default null
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
  v_attachment_path text := nullif(trim(coalesce(p_attachment_path, '')), '');
begin
  if not (public.is_conversations_authorized(p_admin_username, p_admin_password)
          or public.is_online_order_messenger_authorized(p_admin_username, p_admin_password, p_psid)) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;
  if v_message = '' and v_attachment_url is null then
    raise exception 'Message is required.';
  end if;

  insert into public."ChatbotMessages" ("Psid", "Role", "Content", "SentByUsername", "AttachmentUrl", "AttachmentType", "AttachmentPath")
  values (
    p_psid,
    'staff',
    case when v_message = '' then '[Photo]' else v_message end,
    p_admin_username,
    v_attachment_url,
    v_attachment_type,
    v_attachment_path
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

grant execute on function public.admin_send_chatbot_message(text, text, text, text, text, text, text) to anon;
