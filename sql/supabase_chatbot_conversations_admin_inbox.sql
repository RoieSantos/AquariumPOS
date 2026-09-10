-- GMA Conversations inbox (docs/gma-conversations.html, renamed from AI Bot Messages) - lets super
-- users see the Messenger conversations the AI bot is having and, per direct request, pause/unpause
-- the bot per conversation. Deliberately separate from ChatbotConversations."Status" (Active/
-- Escalated, set by the escalate_to_staff tool - see supabase/functions/facebook-messenger-webhook)
-- - per direct confirmation, escalating should NOT silence the bot on its own (it keeps answering,
-- staff just get a heads-up); pausing is its own independent, staff-only switch. Staff replies sent
-- from that same page (supabase_chatbot_staff_reply.sql, via the chatbot-staff-reply Edge Function)
-- auto-pause the conversation too.
--
-- ChatbotConversations/ChatbotMessages are otherwise locked down to the Edge Function's
-- service-role client (see supabase_chatbot_conversations_tables.sql) - these RPCs are the one
-- deliberate super-user-gated window into that data, same is_admin_authorized tier as the rest of
-- AI Bot Setup.

alter table public."ChatbotConversations" add column if not exists "IsPaused" boolean not null default false;

comment on column public."ChatbotConversations"."IsPaused" is 'When true, supabase/functions/facebook-messenger-webhook skips generating an AI reply for this Psid (message is still logged) - set from docs/gma-conversations.html.';

-- ---------------------------------------------------------------------------
-- admin_list_chatbot_conversations: one row per customer conversation, newest activity first,
-- with a short preview of the last message so staff can scan the inbox without opening each one.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_list_chatbot_conversations(text, text, int, int);

create or replace function public.admin_list_chatbot_conversations(
  p_admin_username text,
  p_admin_password text,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  psid text,
  status text,
  is_paused boolean,
  last_message_at_utc timestamptz,
  last_customer_message_at_utc timestamptz,
  created_at_utc timestamptz,
  last_message_preview text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      c."Psid"::text,
      c."Status"::text,
      c."IsPaused",
      c."LastMessageAtUtc",
      c."LastCustomerMessageAtUtc",
      c."CreatedAtUtc",
      (
        select left(m."Content", 200)
        from public."ChatbotMessages" m
        where m."Psid" = c."Psid"
        order by m."CreatedAtUtc" desc
        limit 1
      )::text,
      count(*) over()
    from public."ChatbotConversations" c
    order by coalesce(c."LastMessageAtUtc", c."CreatedAtUtc") desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_chatbot_conversations(text, text, int, int) to anon;

-- ---------------------------------------------------------------------------
-- admin_get_chatbot_conversation_messages: full turn-by-turn history for one conversation, oldest
-- first (matches reading order), capped at p_limit most recent turns.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_get_chatbot_conversation_messages(text, text, text, int);

create or replace function public.admin_get_chatbot_conversation_messages(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_limit int default 100
)
returns table(role text, content text, created_at_utc timestamptz, sent_by_username text)
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
    select m."Role"::text, m."Content"::text, m."CreatedAtUtc", m."SentByUsername"::text
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
-- admin_set_chatbot_conversation_paused: the actual pause/unpause switch, read by the webhook's
-- processMessage before it ever calls Claude.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_set_chatbot_conversation_paused(text, text, text, boolean);

create or replace function public.admin_set_chatbot_conversation_paused(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_is_paused boolean
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
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;

  update public."ChatbotConversations"
  set "IsPaused" = coalesce(p_is_paused, false)
  where "Psid" = p_psid;

  if not found then
    raise exception 'No conversation found for that Psid.';
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_conversation_paused(text, text, text, boolean) to anon;
