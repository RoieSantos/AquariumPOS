-- Keep pg_cron's run log (cron.job_run_details) to the last 7 days - per the database check showing
-- it at 51 MB of a 97 MB database after ~2 months (~7,900 job runs/day, every one logged forever).
-- The log is only ever useful for troubleshooting recent job runs; nothing in the app reads it.
--
--   1. Deletes everything older than 7 days right now.
--   2. Schedules 'purge-cron-run-log' to do the same every day at 03:15 Manila (19:15 UTC).
--
-- Only touches the cron log - no app data, no conversations. Safe to re-run. The freed space is
-- reused by Postgres for new rows (the reported database size may not drop right away, but it stops
-- growing from this table).

delete from cron.job_run_details
where end_time < now() - interval '7 days'
   or (end_time is null and start_time < now() - interval '7 days');

select cron.unschedule('purge-cron-run-log')
where exists (select 1 from cron.job where jobname = 'purge-cron-run-log');

select cron.schedule(
  'purge-cron-run-log',
  '15 19 * * *',
  $$delete from cron.job_run_details
    where end_time < now() - interval '7 days'
       or (end_time is null and start_time < now() - interval '7 days')$$
);

select count(*) as cron_log_rows_left, pg_size_pretty(pg_total_relation_size('cron.job_run_details')) as cron_log_size
from cron.job_run_details;
