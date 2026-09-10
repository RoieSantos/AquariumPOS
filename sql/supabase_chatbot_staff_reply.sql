-- GMA Conversations: lets a staff member send a manual reply to a customer directly from the
-- portal, instead of only being able to view/pause the AI (see supabase_chatbot_conversations_
-- admin_inbox.sql). Per direct request to build an in-house replacement for Pancake's inbox
-- (still Messenger underneath - same webhook/page, just our own interface instead of a third
-- party's) - this is step one: real two-way messaging.
--
-- The actual Messenger delivery (Facebook Send API call) happens in the new
-- supabase/functions/chatbot-staff-reply Edge Function, since that needs FACEBOOK_PAGE_ACCESS_TOKEN
-- (a secret, never exposed to the browser). This RPC is the DB half that function calls first:
-- validate the admin session, then log the message - matching the same "SECURITY DEFINER RPC does
-- the auth check, callers never touch the tables directly" pattern as every other admin_* function
-- in this project, even though in practice only that one Edge Function calls it.

-- 'staff' extends the existing 'user'/'assistant' Role values - found dynamically rather than by
-- guessing Postgres's auto-generated constraint name, so this is safe to re-run regardless of what
-- that name actually is.
do $$
declare
  v_con record;
begin
  for v_con in
    select conname from pg_constraint
    where conrelid = 'public."ChatbotMessages"'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%"Role"%'
  loop
    execute format('alter table public."ChatbotMessages" drop constraint %I', v_con.conname);
  end loop;
end $$;

alter table public."ChatbotMessages" add constraint "ChatbotMessages_Role_check" check ("Role" in ('user', 'assistant', 'staff'));

-- Which staff member sent it - null for 'user'/'assistant' rows, set for 'staff' rows. Shown in
-- the GMA Conversations thread so it's clear who on the team answered.
alter table public."ChatbotMessages" add column if not exists "SentByUsername" varchar(100);

drop function if exists public.admin_send_chatbot_message(text, text, text, text);

create or replace function public.admin_send_chatbot_message(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_message text
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
  if p_message is null or trim(p_message) = '' then
    raise exception 'Message is required.';
  end if;

  insert into public."ChatbotMessages" ("Psid", "Role", "Content", "SentByUsername")
  values (p_psid, 'staff', trim(p_message), p_admin_username);

  -- Counts the same as a bot reply for the follow-up dispatcher's "did the store already answer"
  -- ordering (supabase_chatbot_followups.sql compares LastCustomerMessageAtUtc vs
  -- LastBotMessageAtUtc - it only cares which side spoke last, not whether it was the AI or a
  -- person). Also auto-pauses the conversation: a staff member typing a reply means they're taking
  -- over right now, so the AI should not also answer the customer's next message on top of them -
  -- staff un-pause explicitly from GMA Conversations when they're done.
  update public."ChatbotConversations"
  set "LastMessageAtUtc" = now(),
      "LastBotMessageAtUtc" = now(),
      "IsPaused" = true
  where "Psid" = p_psid;

  if not found then
    raise exception 'No conversation found for that Psid.';
  end if;
end;
$$;

grant execute on function public.admin_send_chatbot_message(text, text, text, text) to anon;
