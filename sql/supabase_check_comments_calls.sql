-- Read-only: are Facebook post comments and Messenger calls reaching us at all?
-- (GMA Conversations' Comments / Calls tabs - supabase_gma_comments_calls_inbox.sql.)
--   setup        - comment auto-reply switch.
--   comment_days - comments received per day, last 14 days. Nothing at all = Facebook isn't sending
--                  the `feed` webhook field for that Page (Meta app > Webhooks > Page > feed, and the
--                  Page must be subscribed to the app).
--   comment      - the last 10 comments (and Page replies) with status / error.
--   call         - the last 10 calls. None at all = Facebook isn't sending the `calls` webhook field
--                  (it may only send calls when call routing is set to the app, not "Meta").

select 'setup' as section,
       'CommentAutoReplyEnabled' as item,
       (select s."CommentAutoReplyEnabled"::text from public."ChatbotAiSettings" s where s."Id" = 1) as status,
       null::text as detail,
       null::timestamptz as at_utc
union all
select * from (
  select 'comment_days', to_char(date_trunc('day', c."ReceivedAtUtc"), 'YYYY-MM-DD'),
         count(*)::text || ' comments',
         string_agg(distinct c."Status", ', '),
         max(c."ReceivedAtUtc")
  from public."FacebookPostComments" c
  where c."ReceivedAtUtc" > now() - interval '14 days'
  group by 1, 2
  order by 2 desc
) days
union all
select * from (
  select 'comment',
         coalesce(c."FromName", c."FromId") || ': ' || coalesce(c."Message", '(no text)'),
         c."Status",
         concat_ws(' | ', 'Page ' || c."PageId", 'Public: ' || c."PublicReplyText", 'DM ' || c."DmStatus", 'Error: ' || c."Error"),
         c."ReceivedAtUtc"
  from public."FacebookPostComments" c
  order by c."ReceivedAtUtc" desc
  limit 10
) recent_comments
union all
select * from (
  select 'call',
         coalesce(cv."CustomerName", k."Psid"),
         coalesce(k."Status", 'no end event'),
         concat_ws(' | ', 'Page ' || k."PageId", 'Duration ' || k."DurationSeconds" || 's', 'FB status ' || k."FacebookStatus"),
         k."StartedAtUtc"
  from public."ChatbotCalls" k
  left join public."ChatbotConversations" cv on cv."Psid" = k."Psid"
  order by k."StartedAtUtc" desc
  limit 10
) recent_calls
union all
select 'call_total', 'All calls ever recorded', (select count(*)::text from public."ChatbotCalls"), null, null;
