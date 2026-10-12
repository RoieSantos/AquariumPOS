-- GMA Conversations: customer mood indicator - per "an indicator for each customer if they sound
-- angry / sad / doubtful / excited".
--
-- The facebook-messenger-webhook Edge Function (mood.ts) reads the latest customer messages with a
-- cheap AI model (Claude Haiku 5.5 by default, MOOD_MODEL secret to change) ~30s after the customer
-- stops typing, and saves one mood + a short reason here. Staff-only: shown as an emoji in the
-- inbox list and thread header; never sent to the customer.
--
--   * ChatbotConversations."CustomerMood"        - angry / impatient / sad / unsure / neutral /
--                                                   happy / excited / ready_to_buy (null = not read yet)
--   * ChatbotConversations."CustomerMoodReason"  - e.g. "Upset the delivery is 2 days late"
--   * ChatbotConversations."CustomerMoodAtUtc"   - when it was last read
--   * admin_list_chatbot_conversations - re-created exactly as in supabase_gma_conversation_mark_unread.sql,
--     plus customer_mood / customer_mood_reason / customer_mood_at_utc (before total_count) and an
--     optional p_mood filter (only conversations currently in that mood).
--
-- Run AFTER supabase_gma_conversation_mark_unread.sql. Safe to re-run. If the mark_unread, tags,
-- pin or unread_seen_by file is ever re-run, run this one again afterwards.

alter table public."ChatbotConversations" add column if not exists "CustomerMood" varchar(20);
alter table public."ChatbotConversations" add column if not exists "CustomerMoodReason" text;
alter table public."ChatbotConversations" add column if not exists "CustomerMoodAtUtc" timestamptz;

-- ---------------------------------------------------------------------------
-- Conversation list + mood.

drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text);
drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text, int);
drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text, int, text);
drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text, int, text, text);

create or replace function public.admin_list_chatbot_conversations(
  p_admin_username text,
  p_admin_password text,
  p_page int default 1,
  p_page_size int default 50,
  p_search text default null,
  p_tag_id int default null,
  p_read_filter text default null,
  p_mood text default null           -- this file: only conversations in this mood
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
  customer_mood text,               -- this file
  customer_mood_reason text,        -- this file
  customer_mood_at_utc timestamptz, -- this file
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
      c."CustomerMood"::text,
      c."CustomerMoodReason",
      c."CustomerMoodAtUtc",
      count(*) over()
    from public."ChatbotConversations" c
    left join public."StaffUsers" s on s."Username" = c."PinnedBy"
    cross join lateral (
      select (c."MarkedUnreadAtUtc" is not null
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
      and (
        coalesce(p_read_filter, '') not in ('unread', 'read')
        or (p_read_filter = 'unread') = u.is_unread
      )
      and (   -- this file
        nullif(trim(coalesce(p_mood, '')), '') is null
        or c."CustomerMood" = trim(p_mood)
      )
    order by c."PinnedAtUtc" desc nulls last, coalesce(c."LastMessageAtUtc", c."CreatedAtUtc") desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_chatbot_conversations(text, text, int, int, text, int, text, text) to anon;

notify pgrst, 'reload schema';
