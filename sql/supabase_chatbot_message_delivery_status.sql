-- GMA Conversations enhancement, per direct request: show the date/time of each message, whether
-- it was actually delivered (vs failed, e.g. outside the 24h window), and whether the customer has
-- seen it. Timestamps already exist (CreatedAtUtc) - this adds the other two.

alter table public."ChatbotMessages" add column if not exists "DeliveryStatus" varchar(20);
alter table public."ChatbotMessages" add column if not exists "SeenAtUtc" timestamptz;

comment on column public."ChatbotMessages"."DeliveryStatus" is '''Sent''/''Failed'' for our own outbound messages (assistant/staff), set by facebook-messenger-webhook or chatbot-staff-reply right after attempting Facebook delivery. Null for inbound ''user'' rows (receiving them from the webhook IS the proof they were received - no separate status needed) and briefly null for an outbound row between insert and the Send API attempt completing.';
comment on column public."ChatbotMessages"."SeenAtUtc" is 'When the customer''s Messenger client reported having read this message (a Facebook ''read'' webhook event, handled by facebook-messenger-webhook''s handleReadReceipt - requires the message_reads field to be subscribed in the App Dashboard). Null until then; always null for inbound ''user'' rows.';

-- ---------------------------------------------------------------------------
-- admin_get_chatbot_conversation_messages: redefined once more to surface delivery_status and
-- seen_at_utc alongside the existing attachment/payment-detection fields.
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
-- admin_send_chatbot_message: redefined to return the new message's Id, so
-- supabase/functions/chatbot-staff-reply can update ITS DeliveryStatus after actually attempting
-- Facebook delivery (the RPC itself can't know that yet at insert time - it runs before the Send
-- API call). Same auth/insert/pause logic as before, just a different return type.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_send_chatbot_message(text, text, text, text);

create or replace function public.admin_send_chatbot_message(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_message text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_message_id bigint;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;
  if p_message is null or trim(p_message) = '' then
    raise exception 'Message is required.';
  end if;

  insert into public."ChatbotMessages" ("Psid", "Role", "Content", "SentByUsername")
  values (p_psid, 'staff', trim(p_message), p_admin_username)
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

grant execute on function public.admin_send_chatbot_message(text, text, text, text) to anon;
