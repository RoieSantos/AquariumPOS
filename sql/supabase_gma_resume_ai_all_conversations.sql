-- ONE-OFF: switch the AI back on in EVERY paused conversation right now - per "can you create me a
-- sql query to enable it all back". Same as clicking "Resume AI" on each chat: clears the pause, the
-- manual-pause flag and any auto-resume timer, for Messenger (Vic) and website (Alice) chats alike.
--
-- Nothing is sent: the bot answers each customer's NEXT message as normal (no burst of replies, no
-- AI tokens from running this). Vic still only replies inside his schedule hours.
-- A staff reply after this pauses that chat again with the usual timer.
--
-- Safe to re-run (a second run just finds nothing paused). Ends in one result: how many were resumed.

with resumed as (
  update public."ChatbotConversations"
  set "IsPaused" = false,
      "PausedManually" = false,
      "AutoResumeAtUtc" = null
  where "IsPaused"
  returning "Psid", "PageId"
)
select
  count(*) as resumed_total,
  count(*) filter (where coalesce("PageId", '') <> 'website') as resumed_messenger,
  count(*) filter (where "PageId" = 'website') as resumed_website
from resumed;
