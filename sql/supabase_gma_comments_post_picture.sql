-- GMA Conversations Comments tab: show the post (caption + photo) above each comment.
--
-- The caption was only saved when a comment arrived through the updated webhook, so older comments
-- (and photo posts with no caption) showed "(photo/video post, or caption not loaded)". Now:
--   * FacebookPostComments."PostPicture" - the post's main photo (Graph full_picture).
--   * When a post isn't saved yet, GMA Conversations asks chatbot-staff-reply (post_info mode) to fetch
--     it from Facebook once; it's saved on every comment of that post.
--   * admin_list_facebook_post_comments - re-created as in supabase_gma_comments_calls_inbox.sql, plus
--     post_picture (after post_permalink).
--
-- Run AFTER supabase_gma_comments_calls_inbox.sql. Safe to re-run. If that file is ever re-run, run
-- this one again afterwards.

alter table public."FacebookPostComments" add column if not exists "PostPicture" text;

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
  post_picture text,
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
           coalesce(c."PostPicture", p."PostPicture"),
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
    -- A comment saved before its post was fetched - borrow the post from another comment on it.
    left join lateral (
      select x."PostMessage", x."PostPermalink", x."PostPicture"
      from public."FacebookPostComments" x
      where x."PostId" = c."PostId" and (x."PostMessage" is not null or x."PostPicture" is not null)
      limit 1
    ) p on c."PostMessage" is null and c."PostPicture" is null
    where c."Status" <> 'PageReply'
    order by c."ReceivedAtUtc" desc
    limit greatest(1, least(coalesce(p_limit, 100), 300));
end;
$$;

grant execute on function public.admin_list_facebook_post_comments(text, text, int) to anon;

notify pgrst, 'reload schema';
