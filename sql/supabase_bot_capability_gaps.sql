-- Backlog of requests Alice (the AI bot) genuinely could not handle - no knowledge, pricing, or
-- tool for it (e.g. aquarium REPAIR services, as opposed to a brand-new custom build she can
-- already quote). Per direct request: "can you do better message? like 'im not programmed to
-- learn this yet, ill log this for future enhancements' - then log the enhancements". Written by
-- the new `log_capability_gap` tool (supabase/functions/_shared/chatbot-engine.ts) whenever she's
-- honest that something is outside what she can do yet, instead of pretending she already handled
-- it (e.g. falsely implying a request was "sent to staff" when nothing was actually escalated).
--
-- Run this in the Supabase SQL Editor.

create table if not exists public."BotCapabilityGaps" (
    "Id" bigint generated always as identity primary key,
    "Channel" text not null,
    "Question" text not null,
    "Status" varchar(20) not null default 'new' check ("Status" in ('new', 'planned', 'done', 'wontfix')),
    "CreatedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_BotCapabilityGaps_CreatedAtUtc" on public."BotCapabilityGaps" ("CreatedAtUtc" desc);

alter table public."BotCapabilityGaps" enable row level security;
revoke all on public."BotCapabilityGaps" from anon, authenticated;

comment on table public."BotCapabilityGaps" is 'Requests Alice honestly could not handle (outside her current knowledge/tools) - a real backlog of what to build next, instead of guessing from memory. Written only by chatbot-engine.ts''s log_capability_gap tool via the service-role key.';

-- ---------------------------------------------------------------------------
-- Staff-facing list/status RPCs - same is_admin_authorized (super user) gate as the rest of the AI
-- bot's admin surface (e.g. supabase_chatbot_conversations_admin_inbox.sql).

drop function if exists public.admin_list_bot_capability_gaps(text, text);

create or replace function public.admin_list_bot_capability_gaps(p_admin_username text, p_admin_password text)
returns setof public."BotCapabilityGaps"
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query select * from public."BotCapabilityGaps" order by "CreatedAtUtc" desc;
end;
$$;

drop function if exists public.admin_update_bot_capability_gap_status(text, text, bigint, text);

create or replace function public.admin_update_bot_capability_gap_status(
  p_admin_username text,
  p_admin_password text,
  p_id bigint,
  p_status text
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

  if p_status not in ('new', 'planned', 'done', 'wontfix') then
    raise exception 'Invalid status.';
  end if;

  update public."BotCapabilityGaps" set "Status" = p_status where "Id" = p_id;
end;
$$;

grant execute on function public.admin_list_bot_capability_gaps(text, text) to anon;
grant execute on function public.admin_update_bot_capability_gap_status(text, text, bigint, text) to anon;

-- Seed this exact incident (per the direct request to log it right away, not just future ones):
-- staff asked Alice, in the portal Team Chat, about repair pricing for an existing 50-gallon
-- aquarium's bottom panel - she has no repair-service knowledge/pricing, only new custom-build
-- quoting (compute_aquarium_quote).
insert into public."BotCapabilityGaps" ("Channel", "Question")
values ('portal-chat', 'magkano service rerepair aquarium 50g bottom? (repair pricing for an existing 50-gallon aquarium''s bottom panel - Alice only knows how to quote brand-new custom builds, not repairs)');
