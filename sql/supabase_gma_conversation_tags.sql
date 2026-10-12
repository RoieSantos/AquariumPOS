-- GMA Conversations: customizable customer tags ("Urgent", "Issue", ...).
--
-- Shared by the team, like pins: a tag on a conversation is visible to every staff member. Only in
-- our own inbox - Facebook's Send API has no labels we use here, so nothing changes in Messenger /
-- Meta Business Suite and the customer never sees it.
--
--   * ChatbotTags              - the tag list (name + color), managed from the Tags picker in the
--                                thread header (any Conversations staff can add/rename/recolor/delete).
--   * ChatbotConversationTags  - which conversation (Psid) has which tag. Deleting a tag removes it
--                                from every conversation (on delete cascade).
--   * admin_list_chatbot_tags / admin_save_chatbot_tag / admin_delete_chatbot_tag
--   * admin_set_chatbot_conversation_tag - tick/untick a tag on one conversation.
--   * admin_list_chatbot_conversations - re-created exactly as in supabase_gma_conversation_pin.sql,
--     plus `tags` (jsonb array of {id, name, color}, before total_count) and a new optional
--     p_tag_id filter (only conversations carrying that tag).
--
-- Seeds "Urgent" and "Issue" (only if missing - renaming/deleting them later sticks).
--
-- Run AFTER supabase_gma_conversation_pin.sql. Safe to re-run. If the pin file is ever re-run, run
-- this one again afterwards.

create table if not exists public."ChatbotTags" (
  "Id" serial primary key,
  "Name" varchar(40) not null,
  "Color" varchar(7) not null default '#64748b',
  "CreatedBy" varchar(100),
  "CreatedAtUtc" timestamptz not null default now()
);
create unique index if not exists "UX_ChatbotTags_Name" on public."ChatbotTags" (lower("Name"));

create table if not exists public."ChatbotConversationTags" (
  "Psid" text not null,
  "TagId" int not null references public."ChatbotTags"("Id") on delete cascade,
  "AddedBy" varchar(100),
  "AddedAtUtc" timestamptz not null default now(),
  primary key ("Psid", "TagId")
);
create index if not exists "IX_ChatbotConversationTags_TagId" on public."ChatbotConversationTags" ("TagId");

-- Only reachable through the security-definer RPCs below.
alter table public."ChatbotTags" enable row level security;
alter table public."ChatbotConversationTags" enable row level security;

insert into public."ChatbotTags" ("Name", "Color", "CreatedBy")
select v.name, v.color, 'system'
from (values ('Urgent', '#dc2626'), ('Issue', '#ea580c')) as v(name, color)
where not exists (select 1 from public."ChatbotTags" t where lower(t."Name") = lower(v.name));

-- ---------------------------------------------------------------------------
-- Tag list.

drop function if exists public.admin_list_chatbot_tags(text, text);

create or replace function public.admin_list_chatbot_tags(
  p_admin_username text,
  p_admin_password text
)
returns table(tag_id int, name text, color text, conversation_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select t."Id", t."Name"::text, t."Color"::text,
           (select count(*) from public."ChatbotConversationTags" ct where ct."TagId" = t."Id")
    from public."ChatbotTags" t
    order by lower(t."Name");
end;
$$;

grant execute on function public.admin_list_chatbot_tags(text, text) to anon;

-- Create (p_tag_id null) or rename/recolor a tag. Returns its id.
drop function if exists public.admin_save_chatbot_tag(text, text, int, text, text);

create or replace function public.admin_save_chatbot_tag(
  p_admin_username text,
  p_admin_password text,
  p_tag_id int,
  p_name text,
  p_color text
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text := trim(coalesce(p_name, ''));
  v_color text := lower(trim(coalesce(p_color, '')));
  v_id int;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_name = '' then
    raise exception 'Tag name is required.';
  end if;
  if length(v_name) > 40 then
    raise exception 'Tag name is too long (40 characters max).';
  end if;
  if v_color !~ '^#[0-9a-f]{6}$' then
    v_color := '#64748b';
  end if;
  if exists (select 1 from public."ChatbotTags" where lower("Name") = lower(v_name) and "Id" is distinct from p_tag_id) then
    raise exception 'A tag named "%" already exists.', v_name;
  end if;

  if p_tag_id is null then
    insert into public."ChatbotTags" ("Name", "Color", "CreatedBy")
    values (v_name, v_color, p_admin_username)
    returning "Id" into v_id;
  else
    update public."ChatbotTags" set "Name" = v_name, "Color" = v_color
    where "Id" = p_tag_id
    returning "Id" into v_id;
    if v_id is null then
      raise exception 'Tag not found.';
    end if;
  end if;
  return v_id;
end;
$$;

grant execute on function public.admin_save_chatbot_tag(text, text, int, text, text) to anon;

drop function if exists public.admin_delete_chatbot_tag(text, text, int);

create or replace function public.admin_delete_chatbot_tag(
  p_admin_username text,
  p_admin_password text,
  p_tag_id int
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
  delete from public."ChatbotTags" where "Id" = p_tag_id; -- cascades to ChatbotConversationTags
end;
$$;

grant execute on function public.admin_delete_chatbot_tag(text, text, int) to anon;

-- ---------------------------------------------------------------------------
-- Tag / untag one conversation.

drop function if exists public.admin_set_chatbot_conversation_tag(text, text, text, int, boolean);

create or replace function public.admin_set_chatbot_conversation_tag(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_tag_id int,
  p_is_tagged boolean
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

  if coalesce(p_is_tagged, false) then
    if not exists (select 1 from public."ChatbotConversations" where "Psid" = p_psid) then
      raise exception 'No conversation found for that Psid.';
    end if;
    if not exists (select 1 from public."ChatbotTags" where "Id" = p_tag_id) then
      raise exception 'Tag not found (it may have just been deleted).';
    end if;
    insert into public."ChatbotConversationTags" ("Psid", "TagId", "AddedBy")
    values (p_psid, p_tag_id, p_admin_username)
    on conflict ("Psid", "TagId") do nothing;
  else
    delete from public."ChatbotConversationTags" where "Psid" = p_psid and "TagId" = p_tag_id;
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_conversation_tag(text, text, text, int, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Conversation list + tags, optional tag filter.

drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text);
drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text, int);

create or replace function public.admin_list_chatbot_conversations(
  p_admin_username text,
  p_admin_password text,
  p_page int default 1,
  p_page_size int default 50,
  p_search text default null,
  p_tag_id int default null         -- this file
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
  tags jsonb,                       -- this file
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
      coalesce((
        select jsonb_agg(jsonb_build_object('id', t."Id", 'name', t."Name", 'color', t."Color") order by lower(t."Name"))
        from public."ChatbotConversationTags" ct
        join public."ChatbotTags" t on t."Id" = ct."TagId"
        where ct."Psid" = c."Psid"
      ), '[]'::jsonb),
      count(*) over()
    from public."ChatbotConversations" c
    left join public."StaffUsers" s on s."Username" = c."PinnedBy"
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
    order by c."PinnedAtUtc" desc nulls last, coalesce(c."LastMessageAtUtc", c."CreatedAtUtc") desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_chatbot_conversations(text, text, int, int, text, int) to anon;

notify pgrst, 'reload schema';
