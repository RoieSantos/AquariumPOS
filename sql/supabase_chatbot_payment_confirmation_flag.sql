-- Per direct follow-up request: the GMA Conversations right-side order panel should auto-fill the
-- Add Payment form (reference/method/amount) and show a "to be confirmed" flag as soon as a
-- conversation with an unconfirmed detected payment screenshot is opened - previously staff had to
-- notice the "Detected Payment (unconfirmed)" card in the message thread and click "Use in Add
-- Payment" themselves (see supabase_chatbot_message_attachments.sql/supabase_chatbot_payment_
-- datetime_and_summary.sql).
--
-- For the auto-fill/flag to actually clear once staff confirms (rather than reappearing every time
-- the conversation is reopened, or never going away), we need to know WHICH detected-payment message
-- staff already acted on - matching by amount/reference alone is unreliable (e.g. two ₱300 GCash
-- payments). So this adds an explicit "applied" timestamp, set by a new admin RPC the frontend calls
-- right after admin_add_automated_order_payment succeeds for a payment it pre-filled. Also exposes
-- each message's own Id (never returned before - nothing needed it) so the frontend has something to
-- pass to that RPC.

alter table public."ChatbotMessages" add column if not exists "DetectedPaymentAppliedAtUtc" timestamptz;

comment on column public."ChatbotMessages"."DetectedPaymentAppliedAtUtc" is 'When staff used this message''s detected payment to actually record a payment (admin_mark_chatbot_payment_applied) - null means the detection is still unconfirmed/outstanding, driving the "to be confirmed" flag on the GMA Conversations order panel. Never set automatically - only by that RPC, called right after admin_add_automated_order_payment succeeds for a pre-filled detected payment.';

-- ---------------------------------------------------------------------------
-- admin_get_chatbot_conversation_messages: redefined once more (same shape as
-- supabase_chatbot_payment_datetime_and_summary.sql, the previous version) to also surface each
-- message's Id (as message_id) and detected_payment_applied_at_utc.
-- ---------------------------------------------------------------------------

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
  seen_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
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
      m."SeenAtUtc"
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

-- ---------------------------------------------------------------------------
-- admin_mark_chatbot_payment_applied: called right after admin_add_automated_order_payment
-- succeeds for a payment the frontend pre-filled from a detected screenshot, so that message's
-- "to be confirmed" flag clears and doesn't come back on the next conversation open.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_mark_chatbot_payment_applied(text, text, bigint);

create or replace function public.admin_mark_chatbot_payment_applied(
  p_admin_username text,
  p_admin_password text,
  p_message_id bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."ChatbotMessages"
  set "DetectedPaymentAppliedAtUtc" = now()
  where "Id" = p_message_id;
end;
$$;

grant execute on function public.admin_mark_chatbot_payment_applied(text, text, bigint) to anon;
