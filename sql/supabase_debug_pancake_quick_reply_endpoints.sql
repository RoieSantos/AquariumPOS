-- ONE-OFF DIAGNOSTIC - not a function, just run this directly in the Supabase SQL Editor and share
-- back the result rows. Not meant to be re-run routinely or referenced elsewhere.
--
-- Answers "can we import our Quick Replies from Pancake?" (GMA Conversations' own quick-reply
-- library - see supabase_chatbot_quick_replies.sql / supabase_chatbot_quick_reply_images.sql) by
-- probing Pancake's Social Inbox public API (https://pages.fm/api/public_api/v1) for a way to list
-- a page's saved "Quick Reply" / canned-content items.
--
-- Prior Pancake research in this repo (supabase_automated_orders_tables.sql's
-- _send_order_confirmation_message) only ever confirmed a SEND endpoint
-- (POST /pages/{page_id}/conversations/{conversation_id}/messages) using the PANCAKE_PUBLIC_API_KEY
-- secret - nothing has confirmed a LIST endpoint for saved replies exists. Public docs
-- (docs.pancake.vn / docs.pancake.biz) mention a "Page's Contents" API category and a `content_ids`
-- field on the send-message body, which strongly suggests page-level saved content items are a real
-- concept server-side - this just tries the most plausible REST paths for actually listing them.
--
-- Includes one already-known-good endpoint (Tags) as a sanity check - if THAT one also fails, the
-- problem is auth/base URL, not that the other paths don't exist.
select
  candidate.label,
  candidate.url_path,
  r.status,
  left(r.content, 800) as body_preview
from (
  values
    ('Sanity check - Tags (known to exist)', '/pages/195716644410829/tags'),
    ('Contents (plural)', '/pages/195716644410829/contents'),
    ('Content (singular)', '/pages/195716644410829/content'),
    ('Saved Replies', '/pages/195716644410829/saved_replies'),
    ('Quick Replies', '/pages/195716644410829/quick_replies'),
    ('Message Templates', '/pages/195716644410829/message_templates')
) as candidate(label, url_path),
lateral (
  select * from extensions.http_get(
    'https://pages.fm/api/public_api/v1' || candidate.url_path || '?page_access_token=' || public._pancake_public_api_key()
  )
) as r;
