-- Per direct follow-up request: when a customer sends a GCash/bank/Maya payment screenshot, the
-- vision pass (extractPaymentDetails in facebook-messenger-webhook) already read amount/method/
-- reference/sender name off it (see supabase_chatbot_message_attachments.sql) - this adds the
-- payment's own date/time (as displayed on the screenshot, e.g. "Nov 15, 2025 3:42 PM") to that
-- same detection pass, so staff reviewing "Detected Payment (unconfirmed)" in the GMA Conversations
-- inbox can also see WHEN the payment claims to have happened (e.g. to notice a screenshot that's
-- days old being reused for a new order). Stored as free text, not timestamptz - screenshot date
-- formats vary by app/bank and there's no reliable way to know the app's timezone, so parsing to a
-- real timestamp risks silently getting it wrong; showing exactly what the screenshot says is safer.
--
-- The webhook's customer-facing auto-ack for a payment screenshot is also upgraded, per the same
-- request, from a one-line "thanks, we'll confirm" into a full order summary (products ordered,
-- total amount, the detected payment marked "To be confirmed by staff", and balance remaining) -
-- that's built entirely in the Edge Function (looks up the customer's most recent AutomatedOrders
-- row by GmaPsid/GmaPageId, same linkage/ordering supabase_gma_conversation_order_details.sql
-- already uses), so no new RPC is needed for it - only the schema/read-side changes below.

alter table public."ChatbotMessages" add column if not exists "DetectedPaymentAtText" varchar(100);

comment on column public."ChatbotMessages"."DetectedPaymentAtText" is 'Payment date/time exactly as displayed on the screenshot (e.g. "Nov 15, 2025 3:42 PM"), read by the same vision pass as the other DetectedPayment* columns. Free text on purpose - screenshot formats/timezones vary too much to safely parse into a real timestamp. Null if not detected.';

-- ---------------------------------------------------------------------------
-- admin_get_chatbot_conversation_messages: redefined once more (same shape as
-- supabase_chatbot_message_delivery_status.sql, the previous version) to also surface
-- detected_payment_at_text for the GMA Conversations inbox's "Detected Payment" card.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_get_chatbot_conversation_messages(text, text, text, int);

create or replace function public.admin_get_chatbot_conversation_messages(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_limit int default 100
)
returns table(
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
