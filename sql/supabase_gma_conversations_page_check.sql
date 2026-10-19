-- Read-only check: "same customer messaged both Pages but Conversations only shows one".
-- Shows, per Facebook Page, how many conversations/messages reached the inbox and when the last one
-- arrived, plus any customer name that exists on more than one Page. If a Page (e.g. RS Pet Stop
-- 195716644410829) is missing or its last message is old, its messages aren't reaching
-- facebook-messenger-webhook (Page not subscribed to the app / token missing), not a display issue.
-- Safe to re-run.

select * from (
  select 'per page' as section,
         coalesce(c."PageId", '(null)') as page_id,
         null::text as customer_name,
         count(distinct c."Psid")::text as conversations,
         count(m.*)::text as messages,
         max(m."CreatedAtUtc") as last_message_at_utc
    from public."ChatbotConversations" c
    left join public."ChatbotMessages" m on m."Psid" = c."Psid"
   group by c."PageId"

  union all

  select 'same name on 2+ pages',
         string_agg(distinct coalesce(c."PageId", '(null)'), ', '),
         c."CustomerName",
         count(distinct c."Psid")::text,
         null,
         max(c."LastMessageAtUtc")
    from public."ChatbotConversations" c
   where nullif(trim(c."CustomerName"), '') is not null
   group by c."CustomerName"
  having count(distinct c."PageId") > 1
) x
order by section, last_message_at_utc desc nulls last;
