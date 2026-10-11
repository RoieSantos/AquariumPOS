-- GMA Conversations: Messenger reactions (❤️ 👍 😆 ...) on messages.
--
--   CustomerReaction - the customer reacted to one of OUR messages (bot/staff reply). Set by
--                      facebook-messenger-webhook's handleReaction from the `message_reactions`
--                      webhook field, matched on FacebookMessageId - which our own sent messages only
--                      carry from this change on (sentMessageFields / chatbot-staff-reply), so older
--                      bot/staff messages can't receive a reaction.
--   StaffReaction    - the Page reacted to a CUSTOMER's message: from GMA Conversations' emoji picker
--                      (chatbot-staff-reply's react mode), or a reaction made in the Meta app.
--
-- admin_get_chatbot_conversation_messages is redefined from its live definition
-- (supabase_gma_conversations_staff_rpc_access.sql) with the two reaction columns added at the end;
-- everything else unchanged.
--
-- Run AFTER supabase_gma_conversations_staff_rpc_access.sql. Safe to re-run.

alter table public."ChatbotMessages" add column if not exists "CustomerReaction" text;
alter table public."ChatbotMessages" add column if not exists "StaffReaction" text;

drop function if exists public.admin_get_chatbot_conversation_messages(text, text, text, int);

create or replace function public.admin_get_chatbot_conversation_messages(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_limit int default 100
)
returns table(
  message_id bigint,
  role text,
  content text,
  created_at_utc timestamptz,
  sent_by_username text,
  attachment_url text,
  attachment_type text,
  detected_payment_amount numeric,
  detected_payment_method text,
  detected_payment_reference text,
  detected_payment_sender_name text,
  detected_payment_at_text text,
  detected_payment_applied_at_utc timestamptz,
  delivery_status text,
  seen_at_utc timestamptz,
  customer_reaction text,  -- this file
  staff_reaction text      -- this file
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      m."Id",
      m."Role"::text,
      m."Content"::text,
      m."CreatedAtUtc",
      m."SentByUsername"::text,
      m."AttachmentUrl"::text,
      m."AttachmentType"::text,
      m."DetectedPaymentAmount",
      m."DetectedPaymentMethod"::text,
      m."DetectedPaymentReference"::text,
      m."DetectedPaymentSenderName"::text,
      m."DetectedPaymentAtText"::text,
      m."DetectedPaymentAppliedAtUtc",
      m."DeliveryStatus"::text,
      m."SeenAtUtc",
      m."CustomerReaction"::text,
      m."StaffReaction"::text
    from (
      select * from public."ChatbotMessages"
      where "Psid" = p_psid
      order by "CreatedAtUtc" desc
      limit v_limit
    ) m
    order by m."CreatedAtUtc" asc;
end;
$$;

grant execute on function public.admin_get_chatbot_conversation_messages(text, text, text, int) to anon;

notify pgrst, 'reload schema';
