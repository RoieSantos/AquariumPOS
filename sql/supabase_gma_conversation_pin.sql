-- GMA Conversations: pin a conversation to the top of the list.
--
-- Shared by the team (like the unread state): a pin is visible to every staff member, so it works as
-- "this one needs follow-up". Only in our own inbox - Facebook's API has no pinning, so nothing
-- changes in Messenger / Meta Business Suite and the customer never sees it.
--
--   * ChatbotConversations."PinnedAtUtc" / "PinnedBy" - null = not pinned.
--   * admin_set_chatbot_conversation_pinned - the 📌 button in the thread header.
--   * admin_list_chatbot_conversations - re-created exactly as in
--     supabase_gma_conversation_unread_seen_by.sql, plus pinned_at_utc / pinned_by (before
--     total_count), and pinned conversations sorted first (most recently pinned on top), then the
--     usual newest-message order.
--
-- Run AFTER supabase_gma_conversation_unread_seen_by.sql. Safe to re-run. If that file is ever
-- re-run, run this one again afterwards.

alter table public."ChatbotConversations" add column if not exists "PinnedAtUtc" timestamptz;
alter table public."ChatbotConversations" add column if not exists "PinnedBy" varchar(100);

-- ---------------------------------------------------------------------------
-- Pin / unpin.

drop function if exists public.admin_set_chatbot_conversation_pinned(text, text, text, boolean);

create or replace function public.admin_set_chatbot_conversation_pinned(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_is_pinned boolean
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
  set "PinnedAtUtc" = case when coalesce(p_is_pinned, false) then now() else null end,
      "PinnedBy" = case when coalesce(p_is_pinned, false) then p_admin_username else null end
  where "Psid" = p_psid;

  if not found then
    raise exception 'No conversation found for that Psid.';
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_conversation_pinned(text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Conversation list + pinned_at_utc / pinned_by, pinned first.

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
  is_unread boolean,
  pinned_at_utc timestamptz,       -- this file
  pinned_by text,                  -- this file
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
      c."PinnedAtUtc",
      coalesce(s."DisplayName", c."PinnedBy")::text,
      count(*) over()
    from public."ChatbotConversations" c
    left join public."StaffUsers" s on s."Username" = c."PinnedBy"
    where
      v_search is null
      or c."CustomerName" ilike '%' || v_search || '%'
      or c."Psid" ilike '%' || v_search || '%'
      or exists (
        select 1 from public."ChatbotMessages" m
        where m."Psid" = c."Psid" and m."Content" ilike '%' || v_search || '%'
      )
    order by c."PinnedAtUtc" desc nulls last, coalesce(c."LastMessageAtUtc", c."CreatedAtUtc") desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_chatbot_conversations(text, text, int, int, text) to anon;

notify pgrst, 'reload schema';
