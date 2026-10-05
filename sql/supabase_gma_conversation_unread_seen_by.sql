-- GMA Conversations: unread conversations shown bold (like Messenger), and "Seen by ..." under the
-- customer's latest message - per "if the message is unread make the block name unread like normal
-- messages do it" + "show who seen this message".
--
--   * Unread is SHARED by the team (same as a Facebook Page inbox): a conversation is unread when the
--     customer's latest message is newer than the last time ANY staff member opened it
--     (ChatbotConversations."StaffReadAtUtc") or replied to it ("LastStaffMessageAtUtc", from
--     supabase_gma_bot_auto_resume.sql - covers replies from the Meta app too). An AI reply does NOT
--     count as read - the conversation stays bold until a person has looked at it.
--   * Seen by: ChatbotConversationReads keeps each staff member's last open time per conversation;
--     admin_get_chatbot_conversation_seen_by returns them for the "Seen by" line.
--   * Existing conversations start as read (StaffReadAtUtc = now on first run), so the list doesn't
--     light up bold all at once - only messages arriving from now on count.
--
-- Re-creates admin_list_chatbot_conversations exactly as in supabase_gma_bot_auto_resume.sql, with
-- is_unread added before total_count.
--
-- Run AFTER supabase_gma_bot_auto_resume.sql. Safe to re-run. If that file is ever re-run, run this
-- one again afterwards.

alter table public."ChatbotConversations" add column if not exists "StaffReadAtUtc" timestamptz;

-- Start clean: everything that exists today counts as read (first run only - rows already set stay).
update public."ChatbotConversations" set "StaffReadAtUtc" = now() where "StaffReadAtUtc" is null;

create table if not exists public."ChatbotConversationReads" (
  "Psid" text not null,
  "Username" varchar(100) not null,
  "LastReadAtUtc" timestamptz not null default now(),
  primary key ("Psid", "Username")
);

alter table public."ChatbotConversationReads" enable row level security; -- RPC access only

-- ---------------------------------------------------------------------------
-- Opening a conversation (or a new message landing in the one already open) marks it read.

create or replace function public.admin_mark_chatbot_conversation_read(
  p_admin_username text,
  p_admin_password text,
  p_psid text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;

  update public."ChatbotConversations" set "StaffReadAtUtc" = now() where "Psid" = p_psid;

  insert into public."ChatbotConversationReads" ("Psid", "Username", "LastReadAtUtc")
  values (p_psid, p_admin_username, now())
  on conflict ("Psid", "Username") do update set "LastReadAtUtc" = excluded."LastReadAtUtc";
end;
$$;

grant execute on function public.admin_mark_chatbot_conversation_read(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Who has opened this conversation, and when (newest first).

create or replace function public.admin_get_chatbot_conversation_seen_by(
  p_admin_username text,
  p_admin_password text,
  p_psid text
)
returns table(
  username text,
  display_name text,
  last_read_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select r."Username"::text,
           coalesce(nullif(trim(s."DisplayName"), ''), r."Username")::text,
           r."LastReadAtUtc"
    from public."ChatbotConversationReads" r
    left join public."StaffUsers" s on s."Username" = r."Username"
    where r."Psid" = p_psid
    order by r."LastReadAtUtc" desc;
end;
$$;

grant execute on function public.admin_get_chatbot_conversation_seen_by(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Conversation list + is_unread.

drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text);

create or replace function public.admin_list_chatbot_conversations(
  p_admin_username text,
  p_admin_password text,
  p_page int default 1,
  p_page_size int default 50,
  p_search text default null
)
returns table(
  psid text,
  page_id text,
  customer_name text,
  status text,
  is_paused boolean,
  last_message_at_utc timestamptz,
  last_customer_message_at_utc timestamptz,
  created_at_utc timestamptz,
  last_message_preview text,
  auto_resume_at_utc timestamptz,
  paused_manually boolean,
  is_unread boolean,               -- this file
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      c."Psid"::text,
      c."PageId"::text,
      c."CustomerName"::text,
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
      c."AutoResumeAtUtc",
      coalesce(c."PausedManually", false),
      (c."LastCustomerMessageAtUtc" is not null
        and c."LastCustomerMessageAtUtc" > greatest(coalesce(c."StaffReadAtUtc", '-infinity'::timestamptz),
                                                    coalesce(c."LastStaffMessageAtUtc", '-infinity'::timestamptz))),
      count(*) over()
    from public."ChatbotConversations" c
    where
      v_search is null
      or c."CustomerName" ilike '%' || v_search || '%'
      or c."Psid" ilike '%' || v_search || '%'
      or exists (
        select 1 from public."ChatbotMessages" m
        where m."Psid" = c."Psid" and m."Content" ilike '%' || v_search || '%'
      )
    order by coalesce(c."LastMessageAtUtc", c."CreatedAtUtc") desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_chatbot_conversations(text, text, int, int, text) to anon;

notify pgrst, 'reload schema';
