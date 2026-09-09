-- AI Messenger chatbot: bot identity/behavior settings, editable from the AI Bot Setup admin page
-- without a code deploy. Deliberately separate from ChatbotStoreInfo
-- (supabase_chatbot_store_info_table.sql) - that table is FAQ content the bot recites verbatim to
-- any customer; this table is persona/tone/instruction knobs that shape HOW the bot talks, folded
-- into the system prompt built by supabase/functions/facebook-messenger-webhook's
-- buildSystemPrompt alongside StoreInfo/CompanyInfo.
--
-- Single-row settings table, same shape/trust posture as ChatbotStoreInfo: public read, write only
-- through a staff-gated RPC. Public read is fine here (no secrets belong in these fields - just
-- personality/tone/greeting text) and keeps the admin page's read path identical to every other
-- single-row settings table in this codebase (CompanyInfo/PromotionSettings/ChatbotStoreInfo all
-- read directly via supabaseClient.from(...).select('*') rather than an RPC).

create table if not exists public."ChatbotAiSettings" (
    "Id" smallint primary key default 1 check ("Id" = 1),
    "BotName" text,
    "CommunicationStyle" text,
    "GreetingMessage" text,
    "CustomDirections" text,
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

alter table public."ChatbotAiSettings" enable row level security;

drop policy if exists "Public read" on public."ChatbotAiSettings";
create policy "Public read" on public."ChatbotAiSettings"
    for select to anon, authenticated using (true);

-- No insert/update/delete policy for anon/authenticated - writes only via the RPC below.
revoke insert, update, delete on public."ChatbotAiSettings" from anon, authenticated;

comment on table public."ChatbotAiSettings" is 'Single-row chatbot persona/tone/instruction settings (bot name, communication style, greeting, custom directions) - publicly readable, edited only via admin_upsert_chatbot_ai_settings.';

drop function if exists public.admin_upsert_chatbot_ai_settings(text, text, text, text, text, text);

create or replace function public.admin_upsert_chatbot_ai_settings(
  p_admin_username text,
  p_admin_password text,
  p_bot_name text,
  p_communication_style text,
  p_greeting_message text,
  p_custom_directions text
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

  insert into public."ChatbotAiSettings"
    ("Id", "BotName", "CommunicationStyle", "GreetingMessage", "CustomDirections", "UpdatedBy", "UpdatedAtUtc")
  values
    (1, p_bot_name, p_communication_style, p_greeting_message, p_custom_directions, p_admin_username, now())
  on conflict ("Id") do update set
    "BotName" = excluded."BotName",
    "CommunicationStyle" = excluded."CommunicationStyle",
    "GreetingMessage" = excluded."GreetingMessage",
    "CustomDirections" = excluded."CustomDirections",
    "UpdatedBy" = excluded."UpdatedBy",
    "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

grant execute on function public.admin_upsert_chatbot_ai_settings(text, text, text, text, text, text) to anon;
