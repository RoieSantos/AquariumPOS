-- READ-ONLY check: which Messenger/website conversations are paused right now, and WHY the bot
-- (Vic / Alice) won't take them back on its own. Safe to re-run; changes nothing.
--
-- reason:
--   'timer running'         - staff replied recently; bot takes over at auto_resume_at (expected)
--   'timer expired'         - bot is back on; un-pauses on the next customer message / cron tick
--   'manual pause'          - a Super User clicked "Pause AI" - stays paused until "Resume AI"
--   'no timer (stuck)'      - paused with no auto-resume time (e.g. paused before the auto-resume
--                             feature existed, or auto-resume minutes = 0) - never comes back by itself
-- The 'settings' row shows the auto-resume minutes and whether the auto-pause trigger is installed.

select
  'settings' as section,
  null::text as psid,
  null::text as customer_name,
  'auto-resume minutes = ' || coalesce((select "StaffAutoResumeMinutes"::text from public."ChatbotAiSettings" where "Id" = 1), '?')
    || '; autopause trigger installed = '
    || exists (select 1 from pg_trigger where tgname = 'trg_chatbot_staff_message_autopause')::text as reason,
  null::timestamptz as last_staff_message_at,
  null::timestamptz as auto_resume_at,
  null::timestamptz as last_customer_message_at
union all
select
  'paused',
  c."Psid",
  c."CustomerName",
  case
    when coalesce(c."PausedManually", false) then 'manual pause'
    when c."AutoResumeAtUtc" is null then 'no timer (stuck)'
    when c."AutoResumeAtUtc" > now() then 'timer running'
    else 'timer expired'
  end,
  c."LastStaffMessageAtUtc",
  c."AutoResumeAtUtc",
  c."LastCustomerMessageAtUtc"
from public."ChatbotConversations" c
where c."IsPaused"
order by section desc, reason, last_customer_message_at desc nulls last;
