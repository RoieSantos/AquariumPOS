-- Facebook Page post comment auto-reply (supabase/functions/facebook-messenger-webhook/comments.ts).
-- Every new comment on the Page's posts gets a short public reply, plus a private Messenger DM when
-- it needs a real answer (price/availability/ordering) or is a complaint.
--
--   1. ChatbotAiSettings.CommentAutoReplyEnabled - on/off switch, toggled from AI Bot Setup.
--   2. FacebookPostComments - one row per comment seen: dedups Facebook redeliveries (CommentId
--      primary key) and logs what was replied, for review. Service role only (no anon access).
--   3. admin_set_chatbot_comment_auto_reply - saves the switch (super users).
--
-- Safe to re-run.

alter table public."ChatbotAiSettings" add column if not exists "CommentAutoReplyEnabled" boolean not null default true;

comment on column public."ChatbotAiSettings"."CommentAutoReplyEnabled" is 'When false, facebook-messenger-webhook ignores Facebook post comments (no public reply, no DM). Toggled on docs/ai-bot-setup.html.';

create table if not exists public."FacebookPostComments" (
    "CommentId" varchar(100) primary key,
    "PageId" varchar(50) not null,
    "PostId" varchar(100),
    "ParentId" varchar(100),
    "FromId" varchar(50) not null,
    "FromName" text,
    "Message" text,
    "PhotoUrl" text,
    -- Processing -> Replied / Skipped / Failed
    "Status" varchar(20) not null default 'Processing',
    "PublicReplyText" text,
    "PublicReplyCommentId" varchar(100),
    "DmText" text,
    "DmStatus" varchar(20),
    "Psid" varchar(50),
    "Error" text,
    "ReceivedAtUtc" timestamptz not null default now(),
    "RepliedAtUtc" timestamptz
);

create index if not exists "IX_FacebookPostComments_FromId_ReceivedAtUtc" on public."FacebookPostComments" ("FromId", "ReceivedAtUtc" desc);
create index if not exists "IX_FacebookPostComments_FromId_PostId" on public."FacebookPostComments" ("FromId", "PostId");

alter table public."FacebookPostComments" enable row level security;
-- No policies: only the Edge Function (service role) reads/writes this table.

create or replace function public.admin_set_chatbot_comment_auto_reply(
  p_admin_username text,
  p_admin_password text,
  p_enabled boolean
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
  update public."ChatbotAiSettings" set "CommentAutoReplyEnabled" = coalesce(p_enabled, true) where "Id" = 1;
  if not found then
    raise exception 'AI settings row not found.';
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_comment_auto_reply(text, text, boolean) to anon;
