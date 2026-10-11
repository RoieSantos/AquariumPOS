-- Read-only: why didn't a Facebook post comment get an auto-reply? (comments.ts)
-- If this errors with 'relation "public.FacebookPostComments" does not exist', then
-- supabase_facebook_comment_auto_reply.sql hasn't been run yet - run that first.
--   setup   - is the on/off switch on?
--   comment - the last 10 comments the webhook received. None at all = Facebook never sent the
--             comment event (feed subscription), or the comment was made AS the Page (skipped).

select 'setup' as section,
       'CommentAutoReplyEnabled' as item,
       (select s."CommentAutoReplyEnabled"::text from public."ChatbotAiSettings" s where s."Id" = 1) as status,
       null::text as detail,
       null::timestamptz as received_at_utc
union all
select * from (
  select 'comment',
         coalesce(c."FromName", c."FromId") || ': ' || coalesce(c."Message", '(no text)'),
         c."Status",
         concat_ws(' | ', 'Public: ' || c."PublicReplyText", 'DM ' || c."DmStatus", 'Error: ' || c."Error"),
         c."ReceivedAtUtc"
  from public."FacebookPostComments" c
  order by c."ReceivedAtUtc" desc
  limit 10
) recent;
