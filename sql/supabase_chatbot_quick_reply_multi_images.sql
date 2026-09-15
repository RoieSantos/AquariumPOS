-- Lets a Quick Reply (supabase_chatbot_quick_replies.sql / supabase_chatbot_quick_reply_images.sql
-- / supabase_chatbot_quick_reply_edit.sql) carry MULTIPLE photos instead of just one - per direct
-- follow-up request. Replaces the single ChatbotQuickReplies.ImagePath/ImageUrl columns with a
-- proper one-to-many child table, since a quick reply with several photos sends them as several
-- separate Messenger messages in sequence anyway (Facebook's Send API can't combine more than one
-- attachment into a single call) - the old columns are left in place, unused, rather than dropped,
-- so nothing is lost if this needs to be rolled back.
create table if not exists public."ChatbotQuickReplyImages" (
    "Id" bigint generated always as identity primary key,
    "QuickReplyId" bigint not null references public."ChatbotQuickReplies"("Id") on delete cascade,
    "ImagePath" varchar(500) not null,
    "ImageUrl" text not null,
    "SortOrder" int not null default 0,
    "CreatedAtUtc" timestamptz not null default now()
);

create index if not exists idx_chatbot_quick_reply_images_quick_reply_id
  on public."ChatbotQuickReplyImages" ("QuickReplyId");

alter table public."ChatbotQuickReplyImages" enable row level security;
revoke all on public."ChatbotQuickReplyImages" from anon, authenticated;

-- One-time migration: carries each existing single-image quick reply's ImagePath/ImageUrl over as
-- its first (and so far only) image. Safe to re-run - only inserts for a quick reply that doesn't
-- already have a row here.
insert into public."ChatbotQuickReplyImages" ("QuickReplyId", "ImagePath", "ImageUrl", "SortOrder")
select "Id", "ImagePath", "ImageUrl", 0
from public."ChatbotQuickReplies"
where "ImageUrl" is not null
  and not exists (
    select 1 from public."ChatbotQuickReplyImages" i where i."QuickReplyId" = "ChatbotQuickReplies"."Id"
  );

-- ---------------------------------------------------------------------------
-- admin_list_chatbot_quick_replies: now returns image_urls as a jsonb array of {id, image_url}
-- objects (ordered by SortOrder) instead of a single image_url.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_chatbot_quick_replies(text, text);

create or replace function public.admin_list_chatbot_quick_replies(
  p_admin_username text,
  p_admin_password text
)
returns table(id bigint, label text, message_text text, image_urls jsonb)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      q."Id",
      q."Label"::text,
      q."MessageText"::text,
      coalesce(
        (
          select jsonb_agg(jsonb_build_object('id', i."Id", 'image_url', i."ImageUrl") order by i."SortOrder", i."Id")
          from public."ChatbotQuickReplyImages" i
          where i."QuickReplyId" = q."Id"
        ),
        '[]'::jsonb
      ) as image_urls
    from public."ChatbotQuickReplies" q
    order by q."SortOrder", q."Id";
end;
$$;

grant execute on function public.admin_list_chatbot_quick_replies(text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_upsert_chatbot_quick_reply: back to text-only (label/message) - a variable-length list of
-- photos doesn't fit as fixed upsert parameters, so photos are now managed one at a time via
-- admin_add_chatbot_quick_reply_image/admin_delete_chatbot_quick_reply_image below. Drops every
-- prior signature this function has had across the last two migrations, in case either is still the
-- live one.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text, text, text, boolean);
drop function if exists public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text, text, text);
drop function if exists public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text);

create or replace function public.admin_upsert_chatbot_quick_reply(
  p_admin_username text,
  p_admin_password text,
  p_id bigint,
  p_label text,
  p_message_text text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
  v_message text := nullif(trim(coalesce(p_message_text, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_label is null or trim(p_label) = '' then
    raise exception 'Label is required.';
  end if;

  -- "Message or a photo" is intentionally NOT enforced here (only Label is a real DB constraint) -
  -- photos are only attachable via admin_add_chatbot_quick_reply_image AFTER this row exists and has
  -- an Id, so there's no reliable way for this function to know a photo is about to follow (whether
  -- creating a brand new photo-only entry, or editing one down to zero photos and zero message text
  -- before the replacement photo lands). The caller (docs/js/gmaConversations.js) already requires a
  -- message or a staged photo before ever calling this.
  if p_id is null then
    insert into public."ChatbotQuickReplies" ("Label", "MessageText", "CreatedBy")
    values (trim(p_label), coalesce(v_message, ''), p_admin_username)
    returning "Id" into v_id;
  else
    update public."ChatbotQuickReplies"
    set "Label" = trim(p_label), "MessageText" = coalesce(v_message, '')
    where "Id" = p_id;

    if not found then
      raise exception 'Quick reply not found.';
    end if;
    v_id := p_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.admin_upsert_chatbot_quick_reply(text, text, bigint, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_add_chatbot_quick_reply_image / admin_delete_chatbot_quick_reply_image: one photo at a time,
-- called right after admin_create_quick_reply_image_upload's signed upload completes for each file
-- picked (supabase_chatbot_quick_reply_images.sql, unchanged) - appends to the end of that quick
-- reply's photo order.
-- ---------------------------------------------------------------------------
drop function if exists public.admin_add_chatbot_quick_reply_image(text, text, bigint, text, text);

create or replace function public.admin_add_chatbot_quick_reply_image(
  p_admin_username text,
  p_admin_password text,
  p_quick_reply_id bigint,
  p_image_path text,
  p_image_url text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id bigint;
  v_next_sort int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_image_path is null or trim(p_image_path) = '' or p_image_url is null or trim(p_image_url) = '' then
    raise exception 'Image path/url is required.';
  end if;
  if not exists (select 1 from public."ChatbotQuickReplies" where "Id" = p_quick_reply_id) then
    raise exception 'Quick reply not found.';
  end if;

  select coalesce(max("SortOrder") + 1, 0) into v_next_sort
  from public."ChatbotQuickReplyImages" where "QuickReplyId" = p_quick_reply_id;

  insert into public."ChatbotQuickReplyImages" ("QuickReplyId", "ImagePath", "ImageUrl", "SortOrder")
  values (p_quick_reply_id, trim(p_image_path), trim(p_image_url), v_next_sort)
  returning "Id" into v_id;

  return v_id;
end;
$$;

grant execute on function public.admin_add_chatbot_quick_reply_image(text, text, bigint, text, text) to anon;

drop function if exists public.admin_delete_chatbot_quick_reply_image(text, text, bigint);

create or replace function public.admin_delete_chatbot_quick_reply_image(
  p_admin_username text,
  p_admin_password text,
  p_image_id bigint
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

  delete from public."ChatbotQuickReplyImages" where "Id" = p_image_id;
end;
$$;

grant execute on function public.admin_delete_chatbot_quick_reply_image(text, text, bigint) to anon;
