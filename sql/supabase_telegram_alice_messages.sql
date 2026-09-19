-- Lets the internal sales team chat with Alice (the AI bot) directly inside the existing Telegram
-- group used for order-confirmed notifications (see supabase_telegram_notifications.sql) - per
-- direct request: "is it possible to create a group message with our sales team with Alice using
-- our inhouse telegram?" Reuses that SAME bot token/chat id (no second bot needed), but adds
-- INBOUND handling (a webhook) on top of the existing OUTBOUND-only notification sender.
--
-- Deliberately its OWN history table, NOT the customer-facing ChatbotConversations/ChatbotMessages
-- (supabase_chatbot_conversations_tables.sql) - an internal staff group isn't a "customer"
-- conversation, and reusing those tables would pollute the GMA Conversations staff inbox with a
-- fake "customer" thread. See supabase/functions/telegram-alice-webhook for the actual bot logic,
-- which runs in the shared engine's `simulate: true` mode (same safety net as the AI Bot Sandbox,
-- docs/ai-bot-sandbox.html) - so nothing staff say to Alice here can create a real order, save a
-- real CRM record, or send a real escalation; every side-effecting tool just describes what it
-- WOULD have done.
--
-- Run this AFTER supabase_telegram_notifications.sql (needs TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID
-- already set up there).

create table if not exists public."TelegramAliceMessages" (
    "Id" bigint generated always as identity primary key,
    "ChatId" text not null,
    "SenderName" text,
    "Role" varchar(10) not null check ("Role" in ('user', 'assistant')),
    "Content" text not null,
    "CreatedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_TelegramAliceMessages_ChatId_CreatedAtUtc"
    on public."TelegramAliceMessages" ("ChatId", "CreatedAtUtc" desc);

alter table public."TelegramAliceMessages" enable row level security;
revoke all on public."TelegramAliceMessages" from anon, authenticated;

comment on table public."TelegramAliceMessages" is 'Turn-by-turn history for internal staff <-> Alice chat inside Telegram, written only by supabase/functions/telegram-alice-webhook via the service-role key. Separate from ChatbotMessages (customer-facing).';

-- Retention - same 60-day window as the customer-facing ChatbotMessages cleanup.
drop function if exists public.cron_cleanup_old_telegram_alice_messages();

create or replace function public.cron_cleanup_old_telegram_alice_messages()
returns void
language sql
security definer
set search_path = public, extensions
as $$
  delete from public."TelegramAliceMessages" where "CreatedAtUtc" < now() - interval '60 days';
$$;

select cron.schedule(
  'cleanup-old-telegram-alice-messages',
  '0 4 * * *',
  $$select public.cron_cleanup_old_telegram_alice_messages();$$
);

-- Explicit grant - _telegram_bot_token() (supabase_telegram_notifications.sql) is revoked from
-- anon/authenticated but was only ever called from other SQL functions before now.
-- telegram-alice-webhook needs to call it directly (as service_role, via supabase-js) to get the
-- raw token for the Telegram Bot API's sendMessage/getMe calls - service_role isn't blocked by the
-- anon/authenticated revoke, but this makes that access explicit rather than relying on it.
grant execute on function public._telegram_bot_token() to service_role;
