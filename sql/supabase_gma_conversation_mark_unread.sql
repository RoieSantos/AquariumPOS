-- GMA Conversations: "Mark as unread" - per "in the conversations can we do unread the conversations".
--
-- Shared by the team, same as the existing unread state (supabase_gma_conversation_unread_seen_by.sql):
-- marking a conversation unread makes it bold + blue dot for every staff member, until someone opens
-- it again. Works even when staff already replied (Messenger-style "remind me later").
--
--   * ChatbotConversations."MarkedUnreadAtUtc" - set by Mark as unread, cleared when anyone opens it.
--   * admin_mark_chatbot_conversation_unread  - new.
--   * admin_mark_chatbot_conversation_read    - re-created as in supabase_gma_conversation_unread_seen_by.sql,
--     now also clears MarkedUnreadAtUtc.
--   * admin_list_chatbot_conversations        - re-created exactly as in supabase_gma_conversation_tags.sql,
--     with is_unread also true while MarkedUnreadAtUtc is set.
--     Also adds an optional p_read_filter ('unread' / 'read', null = all) for the All / Unread / Read
--     filter above the conversation list.
--
-- Run AFTER supabase_gma_conversation_tags.sql. Safe to re-run. If the tags, pin or unread_seen_by file
-- is ever re-run, run this one again afterwards.

alter table public."ChatbotConversations" add column if not exists "MarkedUnreadAtUtc" timestamptz;

-- ---------------------------------------------------------------------------

create or replace function public.admin_mark_chatbot_conversation_unread(
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

  update public."ChatbotConversations" set "MarkedUnreadAtUtc" = now() where "Psid" = p_psid;
end;
$$;

grant execute on function public.admin_mark_chatbot_conversation_unread(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Opening a conversation marks it read (and clears a manual "unread").

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

  update public."ChatbotConversations"
     set "StaffReadAtUtc" = now(), "MarkedUnreadAtUtc" = null   -- MarkedUnreadAtUtc: this file
   where "Psid" = p_psid;

  insert into public."ChatbotConversationReads" ("Psid", "Username", "LastReadAtUtc")
  values (p_psid, p_admin_username, now())
  on conflict ("Psid", "Username") do update set "LastReadAtUtc" = excluded."LastReadAtUtc";
end;
$$;

grant execute on function public.admin_mark_chatbot_conversation_read(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Conversation list: is_unread also covers a manual "Mark as unread", plus the p_read_filter filter.

drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text);
drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text, int);
drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text, int, text);

create or replace function public.admin_list_chatbot_conversations(
  p_admin_username text,
  p_admin_password text,
  p_page int default 1,
  p_page_size int default 50,
  p_search text default null,
  p_tag_id int default null,
  p_read_filter text default null    -- this file: 'unread' / 'read' / null = all
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
  is_unread boolean,
  pinned_at_utc timestamptz,
  pinned_by text,
  tags jsonb,
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
      u.is_unread,
      c."PinnedAtUtc",
      coalesce(s."DisplayName", c."PinnedBy")::text,
      coalesce((
        select jsonb_agg(jsonb_build_object('id', t."Id", 'name', t."Name", 'color', t."Color") order by lower(t."Name"))
        from public."ChatbotConversationTags" ct
        join public."ChatbotTags" t on t."Id" = ct."TagId"
        where ct."Psid" = c."Psid"
      ), '[]'::jsonb),
      count(*) over()
    from public."ChatbotConversations" c
    left join public."StaffUsers" s on s."Username" = c."PinnedBy"
    cross join lateral (
      select (c."MarkedUnreadAtUtc" is not null   -- this file
              or (c."LastCustomerMessageAtUtc" is not null
                  and c."LastCustomerMessageAtUtc" > greatest(coalesce(c."StaffReadAtUtc", '-infinity'::timestamptz),
                                                              coalesce(c."LastStaffMessageAtUtc", '-infinity'::timestamptz)))) as is_unread
    ) u
    where
      (
        v_search is null
        or c."CustomerName" ilike '%' || v_search || '%'
        or c."Psid" ilike '%' || v_search || '%'
        or exists (
          select 1 from public."ChatbotMessages" m
          where m."Psid" = c."Psid" and m."Content" ilike '%' || v_search || '%'
        )
      )
      and (
        p_tag_id is null
        or exists (select 1 from public."ChatbotConversationTags" ct where ct."Psid" = c."Psid" and ct."TagId" = p_tag_id)
      )
      and (   -- this file
        coalesce(p_read_filter, '') not in ('unread', 'read')
        or (p_read_filter = 'unread') = u.is_unread
      )
    order by c."PinnedAtUtc" desc nulls last, coalesce(c."LastMessageAtUtc", c."CreatedAtUtc") desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_chatbot_conversations(text, text, int, int, text, int, text) to anon;

notify pgrst, 'reload schema';
