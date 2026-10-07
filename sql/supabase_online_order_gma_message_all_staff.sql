-- Any active staff member can message GMA Page order customers from Online Orders - order 110119's
-- To-Ship Message dialog failed with "Not authorized." because the sender was neither a Store Manager
-- nor a Production Manager (supabase_online_order_gma_message_managers.sql only allowed those two).
-- Ready to Ship / the Send Message route are open to any staff (is_staff_authorized), so the GMA send
-- now is too.
--
-- Still ONLY to a psid that belongs to an online order (AutomatedOrders.GmaPsid with a
-- PancakeReceiptNo). GMA Conversations itself stays Super User / Conversations Access only (every
-- other GMA Conversations RPC keeps is_conversations_authorized).
--
-- Replaces only is_online_order_messenger_authorized; admin_send_chatbot_message already calls it.
-- Run AFTER supabase_online_order_gma_message_managers.sql; if that file is re-run, run this one
-- again after it. Safe to re-run. No Edge Function redeploy needed.

create or replace function public.is_online_order_messenger_authorized(p_username text, p_password text, p_psid text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  -- Only customers with an online order - not any GMA conversation.
  if not exists (
    select 1 from public."AutomatedOrders" ao
    where ao."GmaPsid" = p_psid and nullif(trim(coalesce(ao."PancakeReceiptNo", '')), '') is not null
  ) then
    return false;
  end if;

  return public.is_staff_authorized(p_username, p_password);
end;
$$;

revoke execute on function public.is_online_order_messenger_authorized(text, text, text) from public, anon, authenticated;
