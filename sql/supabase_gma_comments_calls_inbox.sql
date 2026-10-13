-- GMA Conversations: "Comments" and "Calls" tabs (next to All / Unread / Read).
--
-- Before this, a Facebook post comment only reached the inbox when Alice's private-reply DM went
-- through, and nothing was recorded at all while comment auto-reply was switched off. Calls only
-- showed as a "📞 Missed call" line once the call ended. Now:
--
--   * FacebookPostComments records EVERY comment on the Pages' posts (comments.ts), with the post's
--     caption + link. Status 'Received' = auto-reply is off, nobody has answered yet. The Page's own
--     replies (Alice's, staff's from here, or from Business Suite) are kept as Status 'PageReply' rows
--     under the comment they answer (ParentId), so the tab shows the whole exchange.
--   * RepliedBy - the staff username for a reply sent from GMA Conversations.
--   * admin_list_facebook_post_comments - the Comments tab (customer comments, newest first, with
--     the Page's replies under each).
--   * admin_list_chatbot_calls - the Calls tab (every call, newest first: ringing / answered / missed).
--
-- Run AFTER supabase_facebook_comment_auto_reply.sql and supabase_chatbot_calls.sql. Safe to re-run,
-- but then re-run supabase_gma_comments_post_picture.sql too (it re-creates the comments list with
-- the post photo).

alter table public."FacebookPostComments" add column if not exists "PostMessage" text;
alter table public."FacebookPostComments" add column if not exists "PostPermalink" text;
alter table public."FacebookPostComments" add column if not exists "RepliedBy" varchar(100);

create index if not exists "IX_FacebookPostComments_ParentId" on public."FacebookPostComments" ("ParentId");
create index if not exists "IX_FacebookPostComments_ReceivedAtUtc" on public."FacebookPostComments" ("ReceivedAtUtc" desc);

-- ---------------------------------------------------------------------------
-- Comments tab.

drop function if exists public.admin_list_facebook_post_comments(text, text, int);

create or replace function public.admin_list_facebook_post_comments(
  p_admin_username text,
  p_admin_password text,
  p_limit int default 100
)
returns table(
  comment_id text,
  page_id text,
  post_id text,
  parent_id text,
  post_message text,
  post_permalink text,
  from_id text,
  from_name text,
  message text,
  photo_url text,
  status text,
  public_reply_text text,
  dm_text text,
  dm_status text,
  psid text,
  error text,
  received_at_utc timestamptz,
  page_replies jsonb
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select c."CommentId"::text, c."PageId"::text, c."PostId"::text, c."ParentId"::text,
           coalesce(c."PostMessage", p."PostMessage"), coalesce(c."PostPermalink", p."PostPermalink"),
           c."FromId"::text, c."FromName", c."Message", c."PhotoUrl", c."Status"::text,
           c."PublicReplyText", c."DmText", c."DmStatus"::text, c."Psid"::text, c."Error", c."ReceivedAtUtc",
           coalesce((
             select jsonb_agg(jsonb_build_object(
                      'comment_id', r."CommentId", 'message', r."Message",
                      'replied_by', r."RepliedBy", 'at_utc', r."ReceivedAtUtc")
                    order by r."ReceivedAtUtc")
             from public."FacebookPostComments" r
             where r."ParentId" = c."CommentId"
               and r."Status" = 'PageReply'
               -- Alice's own public reply comes back through the webhook too; it's already shown
               -- from PublicReplyText.
               and r."CommentId" is distinct from c."PublicReplyCommentId"
           ), '[]'::jsonb)
    from public."FacebookPostComments" c
    -- Older rows (before this file) have no caption saved - borrow it from another comment on the post.
    left join lateral (
      select x."PostMessage", x."PostPermalink"
      from public."FacebookPostComments" x
      where x."PostId" = c."PostId" and x."PostMessage" is not null
      limit 1
    ) p on c."PostMessage" is null
    where c."Status" <> 'PageReply'
    order by c."ReceivedAtUtc" desc
    limit greatest(1, least(coalesce(p_limit, 100), 300));
end;
$$;

grant execute on function public.admin_list_facebook_post_comments(text, text, int) to anon;

-- ---------------------------------------------------------------------------
-- Calls tab.

drop function if exists public.admin_list_chatbot_calls(text, text, int);

create or replace function public.admin_list_chatbot_calls(
  p_admin_username text,
  p_admin_password text,
  p_limit int default 100
)
returns table(
  call_id text,
  psid text,
  page_id text,
  customer_name text,
  started_at_utc timestamptz,
  ended_at_utc timestamptz,
  duration_seconds int,
  status text
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select k."CallId"::text, k."Psid"::text, k."PageId"::text, c."CustomerName"::text,
           k."StartedAtUtc", k."EndedAtUtc", k."DurationSeconds",
           coalesce(k."Status"::text,
                    case when k."StartedAtUtc" > now() - interval '2 minutes' then 'Ringing' else 'Unknown' end)
    from public."ChatbotCalls" k
    left join public."ChatbotConversations" c on c."Psid" = k."Psid"
    order by k."StartedAtUtc" desc
    limit greatest(1, least(coalesce(p_limit, 100), 300));
end;
$$;

grant execute on function public.admin_list_chatbot_calls(text, text, int) to anon;

notify pgrst, 'reload schema';
