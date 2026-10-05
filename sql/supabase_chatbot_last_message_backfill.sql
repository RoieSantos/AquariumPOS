-- One-time fix: GMA Conversations sorted / timed conversations by ChatbotConversations."LastMessageAtUtc",
-- which only a bot or staff reply ever moved - a customer message to a PAUSED conversation (no bot reply)
-- left it stuck, e.g. "1h ago" right after the customer sent a video. facebook-messenger-webhook /
-- chatbot-web-reply now update it on every customer message; this catches up the existing rows.
--
-- Moves LastMessageAtUtc forward to the conversation's newest message - never backwards. Safe to
-- re-run (a second run changes nothing). Ends with one result: how many conversations were fixed.

with newest as (
  select m."Psid", max(m."CreatedAtUtc") as last_at
  from public."ChatbotMessages" m
  group by m."Psid"
),
fixed as (
  update public."ChatbotConversations" c
  set "LastMessageAtUtc" = n.last_at
  from newest n
  where n."Psid" = c."Psid"
    and n.last_at > coalesce(c."LastMessageAtUtc", '-infinity'::timestamptz)
  returning c."Psid"
)
select count(*) as conversations_fixed from fixed;
