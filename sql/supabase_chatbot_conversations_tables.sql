-- AI Messenger chatbot: conversation + message history for the NEW plain Facebook Page (direct
-- Graph API webhook, no Pancake involved - see supabase/functions/facebook-messenger-webhook).
-- Separate from AutomatedOrders/OnlineCustomers' Psid columns (supabase_automated_orders_tables.sql,
-- supabase_online_customers_table.sql) on purpose: those belong to a different page's Pancake-backed
-- conversation space, and this page's PSIDs live in a completely separate id space with no shared
-- trust relationship to them.
--
-- ChatbotConversations is one row per customer (keyed by their Facebook PSID for this page).
-- ChatbotMessages is the turn-by-turn history, fed back to Claude as context on every reply
-- (see the Edge Function's history fetch) and trimmed by the cron job at the bottom of this file.
--
-- Both tables are written/read ONLY by the Edge Function via the service-role client (same
-- pattern as supabase/functions/send-web-push/index.ts and public."PushSubscriptions") - RLS is
-- enabled with zero policies and all access revoked from anon/authenticated, matching every other
-- business table in this codebase (Items/AutomatedOrders/etc - see e.g.
-- supabase_automated_orders_tables.sql:45-48). No RPCs are needed for the happy path.

create table if not exists public."ChatbotConversations" (
    "Psid" varchar(255) primary key,
    "PageId" varchar(50) not null,
    "Status" varchar(20) not null default 'Active',
    "LastMessageAtUtc" timestamptz,
    "CreatedAtUtc" timestamptz not null default now()
);

create table if not exists public."ChatbotMessages" (
    "Id" bigint generated always as identity primary key,
    "Psid" varchar(255) not null references public."ChatbotConversations"("Psid") on delete cascade,
    "Role" varchar(10) not null check ("Role" in ('user', 'assistant')),
    "Content" text not null,
    "FacebookMessageId" varchar(100),
    "CreatedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_ChatbotMessages_Psid_CreatedAtUtc" on public."ChatbotMessages" ("Psid", "CreatedAtUtc" desc);

-- Dedup guard: Facebook redelivers the same webhook event on any non-2xx response or timeout, so
-- the Edge Function checks this before replying again - a partial unique index (rather than a
-- plain unique constraint) so it only applies to real inbound messages (FacebookMessageId is null
-- for the assistant's own stored replies).
create unique index if not exists "UX_ChatbotMessages_FacebookMessageId"
    on public."ChatbotMessages" ("FacebookMessageId")
    where "FacebookMessageId" is not null;

alter table public."ChatbotConversations" enable row level security;
alter table public."ChatbotMessages" enable row level security;
revoke all on public."ChatbotConversations" from anon, authenticated;
revoke all on public."ChatbotMessages" from anon, authenticated;

comment on table public."ChatbotConversations" is 'One row per Facebook PSID chatting with the AI Messenger bot on the new page - written only by supabase/functions/facebook-messenger-webhook via the service-role key.';
comment on table public."ChatbotMessages" is 'Turn-by-turn history for ChatbotConversations, fed back to Claude as context. Trimmed by cron_cleanup_old_chatbot_messages below.';

-- ---------------------------------------------------------------------------
-- Retention - the bot only ever needs the last ~20 turns for context (see the Edge Function),
-- so older rows are just bloat. Same cron.schedule pattern as e.g.
-- cron_cleanup_old_online_order_status_photos (supabase_online_order_status_photo.sql).
-- ---------------------------------------------------------------------------

drop function if exists public.cron_cleanup_old_chatbot_messages();

create or replace function public.cron_cleanup_old_chatbot_messages()
returns void
language sql
security definer
set search_path = public, extensions
as $$
  delete from public."ChatbotMessages" where "CreatedAtUtc" < now() - interval '60 days';
$$;

select cron.schedule(
  'cleanup-old-chatbot-messages',
  '0 4 * * *',
  $$select public.cron_cleanup_old_chatbot_messages();$$
);
