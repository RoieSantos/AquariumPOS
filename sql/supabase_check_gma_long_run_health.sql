-- Read-only long-run health check for GMA Conversations / the AI bot - per "can you check if there are
-- things that will break in the long run?". Changes nothing. Run as a whole; one result table.
--
-- What to look for:
--   * attachments oldest file  - should be under ~60 days old. Much older = the 60-day attachment
--                                cleanup isn't deleting files (e.g. missing Vault secret), so photos/
--                                videos pile up in Storage forever.
--   * attachments total size   - Storage quota (free plan 1 GB). Videos make this grow faster now.
--   * conversations total      - the inbox list only loads the newest 100; above that, older ones are
--                                only reachable through search.
--   * failing cron jobs        - one row per job that failed in the last 24h, with its latest error.

select 'attachments files' as section, count(*)::text as value
from storage.objects where bucket_id = 'chatbot-attachments'
union all
select 'attachments total size',
       pg_size_pretty(coalesce(sum((metadata->>'size')::bigint), 0))
from storage.objects where bucket_id = 'chatbot-attachments'
union all
select 'attachments oldest file',
       coalesce(min(created_at)::text || ' (' || (current_date - min(created_at)::date) || ' days old)', '(none)')
from storage.objects where bucket_id = 'chatbot-attachments'
union all
select 'all storage buckets total size',
       pg_size_pretty(coalesce(sum((metadata->>'size')::bigint), 0))
from storage.objects
union all
select 'messages total', count(*)::text from public."ChatbotMessages"
union all
select 'messages oldest', coalesce(min("CreatedAtUtc")::text, '(none)') from public."ChatbotMessages"
union all
select 'conversations total', count(*)::text from public."ChatbotConversations"
union all
select 'longest FacebookMessageId', coalesce(max(length("FacebookMessageId"))::text, '(none)') from public."ChatbotMessages"
union all
select 'failing cron job: ' || coalesce(j.jobname, j.jobid::text),
       count(*)::text || ' failures/24h - ' || coalesce(left(max(d.return_message), 200), '')
from cron.job_run_details d
join cron.job j on j.jobid = d.jobid
where d.start_time > now() - interval '24 hours' and d.status = 'failed'
group by j.jobid, j.jobname;
