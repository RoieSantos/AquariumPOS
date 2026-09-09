-- Portal Chat: Messenger-style 1:1 direct messages between StaffUsers, with live delivery and
-- "who's online" presence. Groups are intentionally NOT built yet - DMs ship first, group
-- conversations are a planned follow-up on top of this same schema (ChatConversations."IsGroup"
-- already exists for that reason, so no later migration is needed to add it).
--
-- Trust model: this follows the SAME "anon full access" tier as Transfer Orders / Month End /
-- Customer Aquarium (see supabase_web_portal_rls_policies.sql's security note) - RLS is enabled
-- but wide open to the anon key, not scoped per-conversation. That's a deliberate, consistent
-- choice, not an oversight: real per-row privacy would need actual Supabase Auth (auth.uid()),
-- which the portal doesn't have (see auth.js - login is a UI-only sessionStorage session). Message
-- bodies here are exactly as private as any other data in the already-open portal tables - no more,
-- no less. Live delivery is done via Realtime Broadcast channels (chat:<ConversationID>), NOT
-- postgres_changes, specifically to avoid a strictly worse exposure: postgres_changes on an openly-
-- policied table would push every DM's contents to every connected browser tab in real time,
-- whereas Broadcast only reaches a channel a client has chosen to join (i.e. a conversation it
-- already knows the ID of from its own membership row).
--
-- Run this in the Supabase SQL Editor AFTER supabase_staff_users_table.sql.

create table if not exists public."ChatConversations" (
    "ConversationID" uuid primary key default gen_random_uuid(),
    "IsGroup" boolean not null default false,
    "Name" varchar(200),
    "CreatedBy" varchar(100) not null references public."StaffUsers"("Username"),
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."ChatConversations" enable row level security;
drop policy if exists "Anon full access" on public."ChatConversations";
create policy "Anon full access" on public."ChatConversations"
    for all to anon, authenticated using (true) with check (true);

create table if not exists public."ChatConversationMembers" (
    "ConversationID" uuid not null references public."ChatConversations"("ConversationID") on delete cascade,
    "Username" varchar(100) not null references public."StaffUsers"("Username"),
    "JoinedAtUtc" timestamptz not null default timezone('utc', now()),
    "LastReadAtUtc" timestamptz,
    constraint "PK_ChatConversationMembers" primary key ("ConversationID", "Username")
);

alter table public."ChatConversationMembers" enable row level security;
drop policy if exists "Anon full access" on public."ChatConversationMembers";
create policy "Anon full access" on public."ChatConversationMembers"
    for all to anon, authenticated using (true) with check (true);

create index if not exists "IX_ChatConversationMembers_Username" on public."ChatConversationMembers" ("Username");

create table if not exists public."ChatMessages" (
    "MessageID" uuid primary key default gen_random_uuid(),
    "ConversationID" uuid not null references public."ChatConversations"("ConversationID") on delete cascade,
    "SenderUsername" varchar(100) not null references public."StaffUsers"("Username"),
    "Body" varchar(4000) not null,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."ChatMessages" enable row level security;
drop policy if exists "Anon full access" on public."ChatMessages";
create policy "Anon full access" on public."ChatMessages"
    for all to anon, authenticated using (true) with check (true);

create index if not exists "IX_ChatMessages_ConversationID_CreatedAtUtc" on public."ChatMessages" ("ConversationID", "CreatedAtUtc");

comment on table public."ChatConversations" is 'One row per chat conversation (DM today; "IsGroup"/"Name" already in place for group chats later).';
comment on table public."ChatConversationMembers" is 'Membership + per-member read state for a ChatConversations row.';
comment on table public."ChatMessages" is 'Messages belonging to a ChatConversations row, newest looked up by CreatedAtUtc.';

-- ---------------------------------------------------------------------------
-- staff_list_chat_directory: who can be messaged. Follows the same p_admin_username/p_admin_password
-- re-verification every StaffUsers-touching RPC uses (StaffUsers itself has RLS enabled with ZERO
-- policies - see supabase_web_portal_rls_policies.sql - so it is NOT reachable directly, only
-- through functions like this one), gated by is_staff_authorized (any active login, not just Super
-- User) same tier as staff_list_production_members in supabase_online_order_production_assignment.sql.

drop function if exists public.staff_list_chat_directory(text, text);

create or replace function public.staff_list_chat_directory(p_admin_username text, p_admin_password text)
returns table(username text, display_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "Username"::text, coalesce(nullif(trim("DisplayName"), ''), "Username")::text
    from public."StaffUsers"
    where "IsActive" and "Username" <> p_admin_username
    order by coalesce(nullif(trim("DisplayName"), ''), "Username");
end;
$$;

-- ---------------------------------------------------------------------------
-- get_or_create_dm_conversation: finds the existing 1:1 (non-group, exactly these two members)
-- conversation between two usernames, or creates one. Centralizing this server-side (instead of
-- "query then insert" from the browser) avoids two staff clicking "Message" on each other at the
-- same moment creating two duplicate DM threads.

drop function if exists public.get_or_create_dm_conversation(text, text);

create or replace function public.get_or_create_dm_conversation(p_username_a text, p_username_b text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_conversation_id uuid;
begin
  if p_username_a is null or p_username_b is null or trim(p_username_a) = '' or trim(p_username_b) = '' then
    raise exception 'Both usernames are required.';
  end if;
  if p_username_a = p_username_b then
    raise exception 'Cannot start a conversation with yourself.';
  end if;

  select c."ConversationID" into v_conversation_id
  from public."ChatConversations" c
  where c."IsGroup" = false
    and exists (select 1 from public."ChatConversationMembers" m where m."ConversationID" = c."ConversationID" and m."Username" = p_username_a)
    and exists (select 1 from public."ChatConversationMembers" m where m."ConversationID" = c."ConversationID" and m."Username" = p_username_b)
    and (select count(*) from public."ChatConversationMembers" m where m."ConversationID" = c."ConversationID") = 2
  limit 1;

  if v_conversation_id is not null then
    return v_conversation_id;
  end if;

  insert into public."ChatConversations" ("IsGroup", "CreatedBy")
  values (false, p_username_a)
  returning "ConversationID" into v_conversation_id;

  insert into public."ChatConversationMembers" ("ConversationID", "Username")
  values (v_conversation_id, p_username_a), (v_conversation_id, p_username_b);

  return v_conversation_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- list_my_chat_conversations: one round-trip for the widget's conversation list - each
-- conversation this user belongs to, the other DM participant, and a last-message preview/unread
-- flag derived from ChatConversationMembers."LastReadAtUtc" vs the newest message's CreatedAtUtc.

drop function if exists public.list_my_chat_conversations(text);

create or replace function public.list_my_chat_conversations(p_username text)
returns table(
  conversation_id uuid,
  is_group boolean,
  name text,
  other_username text,
  last_message text,
  last_message_at timestamptz,
  last_message_sender text,
  unread boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return query
    select
      c."ConversationID",
      c."IsGroup",
      c."Name"::text,
      (select m2."Username"::text from public."ChatConversationMembers" m2
       where m2."ConversationID" = c."ConversationID" and m2."Username" <> p_username limit 1),
      lm."Body"::text,
      lm."CreatedAtUtc",
      lm."SenderUsername"::text,
      coalesce(lm."CreatedAtUtc" > mine."LastReadAtUtc", lm."CreatedAtUtc" is not null)
    from public."ChatConversations" c
    join public."ChatConversationMembers" mine on mine."ConversationID" = c."ConversationID" and mine."Username" = p_username
    left join lateral (
      select "Body", "CreatedAtUtc", "SenderUsername"
      from public."ChatMessages" msg
      where msg."ConversationID" = c."ConversationID"
      order by "CreatedAtUtc" desc
      limit 1
    ) lm on true
    order by coalesce(lm."CreatedAtUtc", c."CreatedAtUtc") desc;
end;
$$;

grant execute on function public.staff_list_chat_directory(text, text) to anon;
grant execute on function public.get_or_create_dm_conversation(text, text) to anon;
grant execute on function public.list_my_chat_conversations(text) to anon;
