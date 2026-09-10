-- AI Messenger chatbot: proactive follow-ups. Lets the bot re-open a conversation instead of only
-- ever reacting to an inbound message (see supabase/functions/facebook-messenger-webhook, which
-- only ever fires off a Messenger webhook POST). See sql/supabase_chatbot_followup_settings.sql
-- for the on/off + delay knobs this reads (edited from AI Bot Setup).
--
-- ChatbotFollowUps is a queue: one row per follow-up to send, regardless of type. Four ways a row
-- gets in here:
--   - Abandoned/Escalation/PendingOrder: detected and inserted by
--     supabase/functions/chatbot-followup-dispatcher on each pg_cron tick (see the trigger function
--     at the bottom of this file) by scanning ChatbotConversations/AutomatedOrders against the
--     *SentAtUtc marker columns added below (each marker prevents re-detecting the same idle
--     stretch/escalation/order every 15 minutes - reset only when the underlying thing changes,
--     e.g. AbandonedNudgeSentAtUtc is cleared whenever the customer sends a new message).
--   - Committed: inserted directly by the webhook's schedule_follow_up tool the moment the bot
--     promises a callback mid-conversation - no detection step, DueAtUtc is already known.
--
-- The dispatcher composes the actual message text at send time (not stored here) so it can react
-- to whatever the conversation looks like by then, and skips (Status='Skipped') anything past
-- Facebook's 24h free-form messaging window rather than attempting a send Meta would reject.

create table if not exists public."ChatbotFollowUps" (
    "Id" bigint generated always as identity primary key,
    "Psid" varchar(255) not null references public."ChatbotConversations"("Psid") on delete cascade,
    "FollowUpType" varchar(20) not null check ("FollowUpType" in ('Abandoned', 'Escalation', 'PendingOrder', 'Committed')),
    "DueAtUtc" timestamptz not null,
    "Reason" text,
    "RelatedOrderNo" varchar(50),
    "Status" varchar(20) not null default 'Pending' check ("Status" in ('Pending', 'Sent', 'Cancelled', 'Skipped')),
    "SkipReason" text,
    "CreatedAtUtc" timestamptz not null default now(),
    "SentAtUtc" timestamptz
);

create index if not exists "IX_ChatbotFollowUps_Pending_Due"
    on public."ChatbotFollowUps" ("DueAtUtc")
    where "Status" = 'Pending';

alter table public."ChatbotFollowUps" enable row level security;
revoke all on public."ChatbotFollowUps" from anon, authenticated;

comment on table public."ChatbotFollowUps" is 'Queue of proactive follow-up messages to send (abandoned-conversation nudges, post-escalation check-ins, unconfirmed-order reminders, and bot-committed callbacks) - written/read only by facebook-messenger-webhook and chatbot-followup-dispatcher via the service-role key.';

-- ---------------------------------------------------------------------------
-- Detection support columns
-- ---------------------------------------------------------------------------

-- LastCustomerMessageAtUtc/LastBotMessageAtUtc: split out of the existing LastMessageAtUtc (which
-- only says *when*, not *who*) so the dispatcher can tell "bot spoke last, customer went quiet"
-- apart from "customer spoke last, bot just hasn't replied yet" without re-deriving it from
-- ChatbotMessages on every scan. Set by the webhook: LastCustomerMessageAtUtc on every inbound
-- message (which also clears AbandonedNudgeSentAtUtc - a fresh reply means any prior idle stretch
-- is over), LastBotMessageAtUtc whenever the bot sends a reply (including a follow-up itself).
alter table public."ChatbotConversations" add column if not exists "LastCustomerMessageAtUtc" timestamptz;
alter table public."ChatbotConversations" add column if not exists "LastBotMessageAtUtc" timestamptz;
alter table public."ChatbotConversations" add column if not exists "AbandonedNudgeSentAtUtc" timestamptz;
alter table public."ChatbotConversations" add column if not exists "EscalatedAtUtc" timestamptz;
alter table public."ChatbotConversations" add column if not exists "EscalationCheckinSentAtUtc" timestamptz;

-- PendingOrder follow-ups are per-order, not per-conversation (a customer can have more than one
-- order), so the "already reminded" marker lives on AutomatedOrders itself rather than on
-- ChatbotConversations. AutomatedOrders."Psid" already exists (set at order submission) - see
-- sql/supabase_automated_orders_tables.sql.
alter table public."AutomatedOrders" add column if not exists "PaymentReminderSentAtUtc" timestamptz;

-- ---------------------------------------------------------------------------
-- pg_cron trigger - fires the dispatcher Edge Function every 15 minutes. Same
-- extensions.http()-from-plpgsql pattern as _trigger_web_push
-- (supabase_web_push_order_confirmed_trigger.sql): pg_cron can't call an Edge Function directly,
-- so a tiny SQL wrapper POSTs to it with the public anon key. 15 minutes is dispatch cadence only -
-- how promptly a due follow-up actually goes out; the per-type delay (how long to wait before a
-- follow-up counts as "due" at all) is configured separately in ChatbotFollowUpSettings.
-- ---------------------------------------------------------------------------

drop function if exists public.cron_dispatch_chatbot_followups();

create or replace function public.cron_dispatch_chatbot_followups()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  -- Public/"publishable" anon key - safe to inline, same value already committed in
  -- docs/js/config.js (window.APP_CONFIG.SUPABASE_ANON_KEY) and reused from
  -- supabase_web_push_order_confirmed_trigger.sql.
  v_anon_key text := 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz';
  v_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/chatbot-followup-dispatcher';
begin
  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '25000');
    perform extensions.http((
      'POST',
      v_url,
      array[
        extensions.http_header('Authorization', 'Bearer ' || v_anon_key),
        extensions.http_header('apikey', v_anon_key)
      ],
      'application/json',
      '{}'
    )::extensions.http_request);
  exception when others then
    null; -- best-effort trigger; the next cron tick 15 minutes from now retries anyway
  end;
end;
$$;

select cron.schedule(
  'dispatch-chatbot-followups',
  '*/15 * * * *',
  $$select public.cron_dispatch_chatbot_followups();$$
);
