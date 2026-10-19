-- GMA Conversations: always show the customer's real Facebook name - per "can we pull all the actual
-- facebook name of the customers instead of changing it on the portal, sometimes the staff are
-- getting confused".
--
-- CustomerName is the CRM / order name: Alice's save_customer_info + create_order tools, the
-- customer-info auto-fill (mood.ts) and the Customer Card all overwrite it, so the inbox name used to
-- change mid-conversation. This adds a separate column that only ever holds the Facebook name:
--
--   * ChatbotConversations."FacebookName" - written by facebook-messenger-webhook (profile /
--     participant lookup) and facebook-conversations-backfill ({ mode: 'names_only' }). Nothing else
--     writes it.
--   * Seeded below from CustomerName wherever that is still the Facebook-sourced name (source null
--     or 'FacebookProfile'). Rows whose name was already replaced get theirs back from Facebook on
--     the customer's next message (webhook), or straight away via a names_only backfill run.
--   * admin_list_chatbot_conversations - re-created exactly as in supabase_gma_conversation_mood.sql,
--     plus facebook_name (before total_count); search also matches FacebookName.
--
-- Run AFTER supabase_gma_conversation_mood.sql. Safe to re-run. If the mood, mark_unread, tags, pin or
-- unread_seen_by file is ever re-run, run this one again afterwards.

alter table public."ChatbotConversations" add column if not exists "FacebookName" varchar(255);

comment on column public."ChatbotConversations"."FacebookName" is 'The customer''s name as Facebook shows it - only set by the Messenger webhook / backfill lookups, never by staff or the bot. CustomerName is the CRM / order name and can differ.';

update public."ChatbotConversations"
set "FacebookName" = "CustomerName"
where "FacebookName" is null
  and nullif(trim(coalesce("CustomerName", '')), '') is not null
  and coalesce("CustomerNameSource", 'FacebookProfile') = 'FacebookProfile';

-- ---------------------------------------------------------------------------
-- Conversation list + facebook_name.

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
  p_mood text default null
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
  customer_mood text,
  customer_mood_reason text,
  customer_mood_at_utc timestamptz,
  facebook_name text,               -- this file
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
      c."FacebookName"::text,       -- this file
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
        or c."FacebookName" ilike '%' || v_search || '%'   -- this file
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
      and (
        nullif(trim(coalesce(p_mood, '')), '') is null
        or c."CustomerMood" = trim(p_mood)
      )
    order by c."PinnedAtUtc" desc nulls last, coalesce(c."LastMessageAtUtc", c."CreatedAtUtc") desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_chatbot_conversations(text, text, int, int, text, int, text, text) to anon;

notify pgrst, 'reload schema';
