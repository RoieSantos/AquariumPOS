-- GMA Conversations: a staff-managed, fully customizable library of canned messages - per direct
-- request, clicking the Quick Reply icon (docs/gma-conversations.html) shows this list, and
-- clicking an item sends it to the customer immediately (no extra typing/confirmation), matching
-- Meta's own "Quick reply" composer icon behavior in Business Suite. Staff can add/delete entries
-- right from that same popover.
--
-- Not to be confused with Facebook's own "quick_replies" BUTTONS feature (tappable options shown
-- to the CUSTOMER, wired up separately in supabase/functions/chatbot-staff-reply) - this table is
-- purely a staff-side shortcut library, never sent to Facebook as structured buttons.
create table if not exists public."ChatbotQuickReplies" (
    "Id" bigint generated always as identity primary key,
    "Label" varchar(100) not null,
    "MessageText" text not null,
    "SortOrder" int not null default 0,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now()
);

alter table public."ChatbotQuickReplies" enable row level security;
revoke all on public."ChatbotQuickReplies" from anon, authenticated;

-- A few starter examples so the list isn't empty on first use - only inserted if the table is
-- currently empty, so this is safe to re-run and never overwrites/duplicates anything staff added.
insert into public."ChatbotQuickReplies" ("Label", "MessageText", "SortOrder", "CreatedBy")
select * from (values
    ('Thank you', 'Thank you for reaching out! How can we help you today? 😊', 1, 'system'),
    ('Please wait', 'Thanks for your patience - let me check that for you.', 2, 'system'),
    ('Store hours', 'We''re open daily from 8:00 AM to 8:00 PM.', 3, 'system')
) as seed(label, message_text, sort_order, created_by)
where not exists (select 1 from public."ChatbotQuickReplies");

create or replace function public.admin_list_chatbot_quick_replies(
  p_admin_username text,
  p_admin_password text
)
returns table(id bigint, label text, message_text text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select q."Id", q."Label"::text, q."MessageText"::text
    from public."ChatbotQuickReplies" q
    order by q."SortOrder", q."Id";
end;
$$;

grant execute on function public.admin_list_chatbot_quick_replies(text, text) to anon;

-- p_id null inserts a new quick reply; a real id updates that existing one (label/message text
-- only - order/management is simple enough not to need a full reorder UI yet).
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
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_label is null or trim(p_label) = '' then
    raise exception 'Label is required.';
  end if;
  if p_message_text is null or trim(p_message_text) = '' then
    raise exception 'Message text is required.';
  end if;

  if p_id is null then
    insert into public."ChatbotQuickReplies" ("Label", "MessageText", "CreatedBy")
    values (trim(p_label), trim(p_message_text), p_admin_username)
    returning "Id" into v_id;
  else
    update public."ChatbotQuickReplies"
    set "Label" = trim(p_label), "MessageText" = trim(p_message_text)
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

create or replace function public.admin_delete_chatbot_quick_reply(
  p_admin_username text,
  p_admin_password text,
  p_id bigint
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

  delete from public."ChatbotQuickReplies" where "Id" = p_id;
end;
$$;

grant execute on function public.admin_delete_chatbot_quick_reply(text, text, bigint) to anon;
