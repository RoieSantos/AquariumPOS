-- READ-ONLY diagnostic: why do the every-minute jobs item-ledger-sales-posting and
-- process-pending-automated-orders show "last ran never (no run log)" on System Tests > Background jobs?
--
-- Suspected cause: pg_cron never starts a job while its previous run is still going. If one run has
-- been hung for 7+ days, purge-cron-run-log (supabase_cron_log_cleanup.sql) deletes its 'running' row
-- too, so the job looks like it never ran at all. The 'Stuck session' rows below show such a run.
--
-- Changes nothing. One result: section / item / detail.

with jobs as (
  select j.jobid, j.jobname, j.schedule, j.active, j.database, j.username, j.nodename, j.command
  from cron.job j
  where j.jobname in ('item-ledger-sales-posting', 'process-pending-automated-orders', 'sync-online-order-details')
)
select '1 Job definition' as section, jobname as item,
       'jobid=' || jobid || ' active=' || active || ' db=' || database || ' user=' || username
       || ' node=' || nodename || ' schedule=' || schedule || ' cmd=' || left(command, 120) as detail
from jobs

union all
select '2 Run log (7 days)', j.jobname,
       count(d.runid) || ' run(s); last start ' || coalesce(max(d.start_time)::text, 'none')
       || '; running now: ' || count(*) filter (where d.status in ('running', 'starting'))
       || '; failed: ' || count(*) filter (where d.status = 'failed')
from jobs j
left join cron.job_run_details d on d.jobid = j.jobid
group by j.jobname

union all
select '3 Stuck session', coalesce(a.application_name, '') || ' pid ' || a.pid,
       'state=' || coalesce(a.state, '') || ' since ' || coalesce(a.query_start::text, '?')
       || ' (' || coalesce(date_trunc('second', now() - a.query_start)::text, '?') || ' ago)'
       || ' wait=' || coalesce(a.wait_event_type || '/' || a.wait_event, 'none')
       || ' query=' || left(a.query, 150)
from pg_stat_activity a
where a.pid <> pg_backend_pid()
  and (a.query ilike '%cron_post_online_order_sales%' or a.query ilike '%cron_process_pending_automated_orders%')

union all
select '4 Queue', 'ItemLedgerOrderDirty older than 15 min',
       (select count(*) from public."ItemLedgerOrderDirty" where "QueuedAtUtc" < now() - interval '15 minutes')::text
       || ' (oldest ' || coalesce((select min("QueuedAtUtc") from public."ItemLedgerOrderDirty")::text, 'none') || ')'

union all
select '4 Queue', 'AutomatedOrders PancakeSyncStatus = Pending',
       (select count(*) from public."AutomatedOrders" where "PancakeSyncStatus" = 'Pending')::text

union all
select '5 pg_cron', 'max_running_jobs / sessions open now',
       coalesce(current_setting('cron.max_running_jobs', true), '?') || ' / '
       || (select count(*) from pg_stat_activity where application_name ilike 'pg_cron%')::text

order by 1, 2;
