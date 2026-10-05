-- Read-only check: how big is pg_cron's run log (cron.job_run_details) and how does it compare to the
-- whole database - per "how is it affecting our database health?". Changes nothing. Run as a whole;
-- one result table.

select 'cron log rows' as section, count(*)::text as value
from cron.job_run_details
union all
select 'cron log size (table + indexes)', pg_size_pretty(pg_total_relation_size('cron.job_run_details'))
union all
select 'cron log oldest entry', coalesce(min(start_time)::text, '(empty)')
from cron.job_run_details
union all
select 'cron runs last 24h', count(*)::text
from cron.job_run_details
where start_time > now() - interval '24 hours'
union all
select 'cron failed runs last 24h', count(*)::text
from cron.job_run_details
where start_time > now() - interval '24 hours' and status = 'failed'
union all
select 'whole database size', pg_size_pretty(pg_database_size(current_database()))
union all
select 'ChatbotMessages size (table + indexes)', pg_size_pretty(pg_total_relation_size('public."ChatbotMessages"'));
