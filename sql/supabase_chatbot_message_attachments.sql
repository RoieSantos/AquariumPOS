-- Lets the GMA chatbot webhook (supabase/functions/facebook-messenger-webhook) store an image a
-- customer sends (e.g. a GCash payment screenshot) instead of silently skipping it - previously
-- ANY message with an attachment and no text was dropped entirely ("out of v1 scope", see that
-- file's main loop before this). Direct follow-up after "will this balloon the database" -
-- answered no at the time (attachments were never captured at all) - this is the deliberate
-- follow-up build: yes, capture them, but bounded the same way ChatbotMessages already is (a
-- 60-day retention cron), so Storage never grows unbounded either.
--
-- Bucket is PRIVATE (unlike online-order-status-photos, which is public because Messenger/Pancake
-- need to fetch it directly) - these are inbound customer photos, viewed only by authenticated
-- staff inside the GMA Conversations inbox, so there's no reason to leave them open on the public
-- internet. A signed URL (60-day expiry, matching the message retention window) is generated once
-- at ingestion time and stored directly on the message row - simpler than re-signing on every
-- read, and the Edge Function already holds the service-role key it needs to do this directly via
-- supabase-js (no Vault/HTTP-signing dance needed there, unlike the browser-upload flows in
-- supabase_online_order_status_photo.sql - this upload happens entirely server-side, Facebook's
-- CDN straight into our Storage, the browser is never involved).
--
-- Only image attachments are downloaded/stored - video/audio/file/location attachments are still
-- skipped (same "out of v1 scope" cut as before), and a customer message that's ONLY an attachment
-- (no text) skips the AI turn entirely (nothing useful for Claude to respond to) in favor of a
-- short canned acknowledgement - see processMessage's handling in the webhook.
--
-- Also adds DetectedPayment* columns: every stored image now gets a Claude vision pass
-- (extractPaymentDetails in the webhook) to see if it's a payment screenshot (GCash/Maya/bank
-- transfer) and, if so, read off the amount/reference/method/sender name. This is a suggestion
-- surfaced to staff in the inbox, never an automatic payment log - see the column comments below.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'chatbot-attachments',
  'chatbot-attachments',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
on conflict (id) do nothing;

alter table public."ChatbotMessages" add column if not exists "AttachmentPath" varchar(500);
alter table public."ChatbotMessages" add column if not exists "AttachmentUrl" text;
alter table public."ChatbotMessages" add column if not exists "AttachmentType" varchar(30);

comment on column public."ChatbotMessages"."AttachmentPath" is 'Storage object path (bucket-relative) in the chatbot-attachments bucket, if this message carried an image - needed to remove the object from Storage on retention cleanup (see cron_cleanup_old_chatbot_messages below). Null for text-only messages.';
comment on column public."ChatbotMessages"."AttachmentUrl" is 'Signed URL (60-day expiry, generated once at ingestion) for the stored image, for the GMA Conversations inbox to render inline.';
comment on column public."ChatbotMessages"."AttachmentType" is 'Facebook attachment type (currently always "image" - video/audio/file/location are not downloaded).';

-- Populated by a Claude vision pass in facebook-messenger-webhook (extractPaymentDetails) run
-- against every stored image attachment, to see if it's a payment screenshot (GCash/Maya/bank
-- transfer receipt) and pull out the amount/reference/method/sender name. Purely a SUGGESTION for
-- staff, surfaced in the GMA Conversations inbox next to the photo with a "Use in Add Payment"
-- button that pre-fills the existing Add Payment form (admin_add_automated_order_payment) - never
-- posted automatically, since a misread screenshot would corrupt a real payment record.
alter table public."ChatbotMessages" add column if not exists "DetectedPaymentAmount" numeric(18,2);
alter table public."ChatbotMessages" add column if not exists "DetectedPaymentMethod" varchar(30);
alter table public."ChatbotMessages" add column if not exists "DetectedPaymentReference" varchar(200);
alter table public."ChatbotMessages" add column if not exists "DetectedPaymentSenderName" varchar(200);

comment on column public."ChatbotMessages"."DetectedPaymentAmount" is 'Amount Claude''s vision pass read off a payment screenshot attachment, if any. Null when the attachment wasn''t recognized as a payment screenshot (or there was no attachment). A suggestion only - never auto-applied to any order''s payments.';
comment on column public."ChatbotMessages"."DetectedPaymentMethod" is 'One of GCash / Maya / Bank Transfer / Other, as read off the screenshot by the vision pass. Null if not detected.';
comment on column public."ChatbotMessages"."DetectedPaymentReference" is 'Reference/transaction number read off the screenshot by the vision pass, if visible. Null if not detected.';
comment on column public."ChatbotMessages"."DetectedPaymentSenderName" is 'Sender name read off the screenshot by the vision pass, if visible. Null if not detected.';

-- ---------------------------------------------------------------------------
-- admin_get_chatbot_conversation_messages: redefined to also surface the attachment and detected-
-- payment fields so docs/js/gmaConversations.js can render an inline photo plus a "Use in Add
-- Payment" suggestion card.
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
  detected_payment_sender_name text
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
      m."DetectedPaymentSenderName"::text
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
-- cron_cleanup_old_chatbot_messages: redefined (same 60-day window as
-- supabase_chatbot_conversations_tables.sql) to also delete each message's Storage object BEFORE
-- deleting the row - otherwise the image would be orphaned in Storage forever once nothing in the
-- database points to it, exactly the "balloon" outcome this whole feature was built to avoid.
-- Uses the same Vault-secret + Storage REST pattern as cron_cleanup_old_online_order_status_photos
-- (supabase_online_order_status_photo.sql) - a plain Postgres cron function has no supabase-js
-- client of its own, unlike the Edge Function that uploads these in the first place.
-- ---------------------------------------------------------------------------

drop function if exists public.cron_cleanup_old_chatbot_messages();

create or replace function public.cron_cleanup_old_chatbot_messages()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bucket text := 'chatbot-attachments';
  v_base_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co';
  v_service_role_key text;
  v_row record;
begin
  select decrypted_secret into v_service_role_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if v_service_role_key is not null and trim(v_service_role_key) <> '' then
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

    for v_row in
      select "Id", "AttachmentPath"
      from public."ChatbotMessages"
      where "CreatedAtUtc" < now() - interval '60 days'
        and "AttachmentPath" is not null
    loop
      begin
        perform extensions.http((
          'POST',
          v_base_url || '/storage/v1/object/remove/' || v_bucket,
          array[
            extensions.http_header('Authorization', 'Bearer ' || v_service_role_key),
            extensions.http_header('apikey', v_service_role_key)
          ],
          'application/json',
          jsonb_build_object('prefixes', jsonb_build_array(v_row."AttachmentPath"))::text
        )::extensions.http_request);
      exception when others then
        null; -- storage-side cleanup is best-effort; the row is still deleted below either way
      end;
    end loop;
  end if;
  -- If the Vault secret isn't configured, attachment storage objects just won't be cleaned up
  -- this run (rows still get deleted below on schedule) - same graceful-skip as
  -- cron_cleanup_old_online_order_status_photos.

  delete from public."ChatbotMessages" where "CreatedAtUtc" < now() - interval '60 days';
end;
$$;

select cron.schedule(
  'cleanup-old-chatbot-messages',
  '0 4 * * *',
  $$select public.cron_cleanup_old_chatbot_messages();$$
);
