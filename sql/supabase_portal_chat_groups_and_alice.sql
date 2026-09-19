-- Adds two things on top of the existing Portal Chat widget (supabase_portal_chat_tables.sql):
--
--   1. GROUP conversations - that file's schema already had "IsGroup"/"Name" ready for this
--      ("Groups are intentionally NOT built yet... a planned follow-up on top of this same
--      schema"), this is that follow-up: create_group_conversation() lets the widget's "New Group"
--      tab create a multi-member conversation the same way get_or_create_dm_conversation() creates
--      a 1:1 one.
--   2. Alice, the AI bot, as an addressable contact INSIDE the portal chat widget - per direct
--      request "i want alice and the GC to live only in the portal" (i.e. no external Telegram
--      app - see supabase_telegram_alice_messages.sql/telegram-alice-webhook, which stays deployed
--      but unused/dormant now that this is the chosen path). Staff can DM "Alice" directly (always
--      replies) or add her to a group and type "@Alice" in a message (only replies when mentioned
--      there - never to ordinary staff back-and-forth). See supabase/functions/portal-chat-alice-
--      reply for the actual reply logic, which reuses the same shared engine as Messenger/the
--      website widget but in `simulate: true` mode (same safety net as the AI Bot Sandbox) - nothing
--      said to her in portal chat creates a real order/escalation/CRM save.
--
-- Run this AFTER supabase_portal_chat_tables.sql.

-- ---------------------------------------------------------------------------
-- Alice's directory row - a StaffUsers row that exists ONLY so she has a valid "Username" for the
-- ChatMessages/ChatConversationMembers foreign keys and shows up in staff_list_chat_directory's
-- normal "everyone else" listing (no code change needed there). IsActive stays true (so the
-- directory picks her up) but the password hash is a random, never-revealed value, so
-- verify_login/is_admin_authorized/is_staff_authorized can never actually authenticate as her -
-- she cannot log in, only be messaged. This follows the same "portal login is UI-gating, not real
-- security" model already documented at the top of supabase_staff_users_table.sql.
insert into public."StaffUsers" ("Username", "PasswordHash", "DisplayName", "IsActive")
select 'alice', crypt(gen_random_uuid()::text, gen_salt('bf')), 'Alice (AI Assistant)', true
where not exists (select 1 from public."StaffUsers" where "Username" = 'alice');

-- ---------------------------------------------------------------------------
-- create_group_conversation: same "centralize server-side" reasoning as get_or_create_dm_conversation
-- in supabase_portal_chat_tables.sql. p_member_usernames is every OTHER member (the creator is
-- added automatically) - include 'alice' in that array to start the group with her already in it.
drop function if exists public.create_group_conversation(text, text, text, text[]);

create or replace function public.create_group_conversation(
  p_username text,
  p_password text,
  p_name text,
  p_member_usernames text[]
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_conversation_id uuid;
  v_member text;
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  if p_member_usernames is null or array_length(p_member_usernames, 1) is null then
    raise exception 'Select at least one other member.';
  end if;

  insert into public."ChatConversations" ("IsGroup", "Name", "CreatedBy")
  values (true, coalesce(nullif(trim(p_name), ''), 'Group Chat'), p_username)
  returning "ConversationID" into v_conversation_id;

  insert into public."ChatConversationMembers" ("ConversationID", "Username")
  values (v_conversation_id, p_username);

  foreach v_member in array p_member_usernames loop
    if v_member is not null and v_member <> p_username then
      insert into public."ChatConversationMembers" ("ConversationID", "Username")
      values (v_conversation_id, v_member)
      on conflict do nothing;
    end if;
  end loop;

  return v_conversation_id;
end;
$$;

grant execute on function public.create_group_conversation(text, text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- is_alice_conversation_member: lets the widget (and the Edge Function) check, server-side,
-- whether "alice" is actually in a given conversation before triggering a reply - so a group chat
-- she was never added to can't get a bot reply just because someone typed "@Alice" in it.
drop function if exists public.is_alice_conversation_member(uuid);

create or replace function public.is_alice_conversation_member(p_conversation_id uuid)
returns boolean
language sql
security definer
set search_path = public, extensions
stable
as $$
  select exists (
    select 1 from public."ChatConversationMembers"
    where "ConversationID" = p_conversation_id and "Username" = 'alice'
  );
$$;

grant execute on function public.is_alice_conversation_member(uuid) to anon, service_role;
