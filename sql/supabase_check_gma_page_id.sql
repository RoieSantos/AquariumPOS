-- Read-only: the Facebook Page ID(s) the Messenger bot has actually received messages for
-- (ChatbotConversations.PageId, stamped by facebook-messenger-webhook). Needed when generating a
-- Page access token in the Graph API Explorer: GET <PageId>?fields=name,access_token
-- 'website' / sandbox ids are excluded - only real Facebook Page ids.

select "PageId", count(*) as conversations, max("LastMessageAtUtc") as last_message_at
from public."ChatbotConversations"
where "PageId" ~ '^[0-9]+$'
group by "PageId"
order by conversations desc;
