-- GMA Conversations: search the conversation list, per direct request "same way we search from
-- meta too" - matches customer name (primary case, like Messenger's own contact search) or Psid,
-- and also matches message CONTENT (like Messenger's search also surfacing a conversation because
-- of something said in it, not just the contact's name).

drop function if exists public.admin_list_chatbot_conversations(text, text, int, int);

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
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
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
