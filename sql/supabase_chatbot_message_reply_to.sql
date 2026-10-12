-- GMA Conversations: Messenger "reply to a specific message" (the quoted-message reply).
--
--   ReplyToMid - Facebook mid of the message this one replies to. Set by:
--                * chatbot-staff-reply, when staff picks "Reply" on a bubble and Facebook accepted the
--                  send with reply_to (so the customer really sees it as a quoted reply);
--                * facebook-messenger-webhook, when the customer (or a Meta-app staff echo) replies to a
--                  specific message (message.reply_to.mid).
--
-- admin_get_chatbot_conversation_messages is redefined from its live definition
-- (supabase_chatbot_message_reactions.sql) with reply_to_* columns added at the end - the quoted
-- message is resolved by matching ReplyToMid against FacebookMessageId in the same conversation
-- (null when it was never recorded here, e.g. older than the backfill); everything else unchanged.
--
-- Run AFTER supabase_chatbot_message_reactions.sql. Safe to re-run.

alter table public."ChatbotMessages" add column if not exists "ReplyToMid" text;

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
  customer_reaction text,
  staff_reaction text,
  reply_to_mid text,              -- this file
  reply_to_message_id bigint,     -- this file
  reply_to_role text,             -- this file
  reply_to_content text,          -- this file
  reply_to_attachment_type text   -- this file
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
      m."StaffReaction"::text,
      m."ReplyToMid"::text,
      r."Id",
      r."Role"::text,
      r."Content"::text,
      r."AttachmentType"::text
    from (
      select * from public."ChatbotMessages"
      where "Psid" = p_psid
      order by "CreatedAtUtc" desc
      limit v_limit
    ) m
    left join public."ChatbotMessages" r
      on m."ReplyToMid" is not null
     and r."FacebookMessageId" = m."ReplyToMid"
     and r."Psid" = p_psid
    order by m."CreatedAtUtc" asc;
end;
$$;

grant execute on function public.admin_get_chatbot_conversation_messages(text, text, text, int) to anon;

notify pgrst, 'reload schema';
