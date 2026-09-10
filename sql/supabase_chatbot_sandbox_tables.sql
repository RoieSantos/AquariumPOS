-- Portal-only AI bot testing sandbox (docs/ai-bot-sandbox.html) - lets a super user test the
-- Messenger bot's conversational/tool-use logic from the portal, without a real Facebook
-- conversation. Built per direct request while Meta was temporarily restricting messaging on the
-- real Page (a live testing outage) - the sandbox works regardless of Meta's messaging status
-- since it never touches the Facebook Send API at all (see supabase/functions/chatbot-sandbox-reply
-- and its "simulate" mode in supabase/functions/_shared/chatbot-engine.ts).
--
-- Per direct decision, this is FULLY SEPARATE from the real ChatbotConversations/ChatbotMessages
-- tables - a sandbox test conversation must never show up mixed into the real customer inbox
-- (docs/gma-conversations.html) or be confused with real customer history. One ongoing test
-- conversation per staff username (keyed by "Username", not a fake Psid) - simple, resettable, and
-- there's no need for multiple concurrent sandbox threads per person.
--
-- Only two RPCs here (both super-user-gated, same is_admin_authorized tier as AI Bot Setup): one to
-- read a tester's own sandbox history, one to reset it. Actually SENDING a sandbox message and
-- getting the bot's reply goes through the chatbot-sandbox-reply Edge Function instead (it needs to
-- call Anthropic + run the tool-use loop, not something a plain SQL RPC can do) - that function
-- inserts both sides of the exchange directly using its own service-role client.

create table if not exists public."ChatbotSandboxMessages" (
  "Id" bigint generated always as identity primary key,
  "Username" text not null,
  "Role" text not null check ("Role" in ('user', 'assistant')),
  "Content" text not null,
  "CreatedAtUtc" timestamptz not null default now()
);

create index if not exists idx_chatbot_sandbox_messages_username_created
  on public."ChatbotSandboxMessages" ("Username", "CreatedAtUtc");

alter table public."ChatbotSandboxMessages" enable row level security;

-- No anon/authenticated policies - locked down to service-role (chatbot-sandbox-reply) and the two
-- re-verifying RPCs below, same trust model as ChatbotConversations/ChatbotMessages themselves.

drop function if exists public.admin_get_chatbot_sandbox_messages(text, text);

create or replace function public.admin_get_chatbot_sandbox_messages(p_admin_username text, p_admin_password text)
returns table(role text, content text, created_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select m."Role"::text, m."Content"::text, m."CreatedAtUtc"
    from public."ChatbotSandboxMessages" m
    where m."Username" = p_admin_username
    order by m."CreatedAtUtc" asc
    limit 200;
end;
$$;

grant execute on function public.admin_get_chatbot_sandbox_messages(text, text) to anon;

drop function if exists public.admin_reset_chatbot_sandbox(text, text);

create or replace function public.admin_reset_chatbot_sandbox(p_admin_username text, p_admin_password text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."ChatbotSandboxMessages" where "Username" = p_admin_username;
end;
$$;

grant execute on function public.admin_reset_chatbot_sandbox(text, text) to anon;
