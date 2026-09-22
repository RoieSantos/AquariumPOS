-- Read-only checks for the Messenger chatbot's proactive follow-ups (sql/supabase_chatbot_followups.sql,
-- sql/supabase_chatbot_followup_settings.sql, supabase/functions/chatbot-followup-dispatcher). Nothing
-- here writes anything; run any of these in the SQL editor when a follow-up you expected never arrived.

-- 1. Current settings - is "Abandoned" actually enabled, and what delay is really saved?
select "AbandonedEnabled", "AbandonedDelayMinutes",
       "EscalationEnabled", "EscalationDelayMinutes",
       "PendingOrderEnabled", "PendingOrderDelayMinutes",
       "CommittedEnabled", "UpdatedAtUtc"
from public."ChatbotFollowUpSettings";

-- 2. Is the cron job alive, and is it actually firing? (jobid from row 1 feeds row 2's run history.)
select jobid, jobname, schedule, active from cron.job where jobname = 'dispatch-chatbot-followups';

select jrd.status, jrd.return_message, jrd.start_time, jrd.end_time
from cron.job_run_details jrd
join cron.job j on j.jobid = jrd.jobid
where j.jobname = 'dispatch-chatbot-followups'
order by jrd.start_time desc
limit 20;

-- 3. The actual queue - anything ever enqueued, and what happened to it (Pending/Sent/Skipped)?
select "Id", "Psid", "FollowUpType", "DueAtUtc", "Status", "SkipReason", "CreatedAtUtc", "SentAtUtc"
from public."ChatbotFollowUps"
order by "CreatedAtUtc" desc
limit 50;

-- 4. Conversations that SHOULD be triggering an "Abandoned" nudge right now, per the detection logic
--    in the dispatcher (bot spoke last, customer has gone quiet since, no nudge sent yet). If your
--    test conversation shows up here but no row exists in query 3, the dispatcher isn't running or
--    is failing before it inserts - check query 2's return_message.
select "Psid", "Status", "LastBotMessageAtUtc", "LastCustomerMessageAtUtc", "AbandonedNudgeSentAtUtc",
       extract(epoch from (now() - "LastBotMessageAtUtc")) / 60 as minutes_since_bot_replied
from public."ChatbotConversations"
where "Status" = 'Active'
  and "LastBotMessageAtUtc" is not null
  and "AbandonedNudgeSentAtUtc" is null
  and (coalesce("LastCustomerMessageAtUtc" < "LastBotMessageAtUtc", true))
order by "LastBotMessageAtUtc" desc
limit 50;
