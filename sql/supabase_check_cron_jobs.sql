-- Read-only check: every pg_cron job, how often it ran / failed in the last 24h, and its latest
-- error - per "cron runs last 24h = 7905, failed = 74" (which jobs run that often, and what's failing).
-- Changes nothing. Run as a whole; one result table, busiest jobs first.

select
  j.jobid,
  j.jobname,
  j.schedule,
  j.active,
  count(d.runid) filter (where d.start_time > now() - interval '24 hours') as runs_24h,
  count(d.runid) filter (where d.start_time > now() - interval '24 hours' and d.status = 'failed') as failed_24h,
  (
    select left(d2.return_message, 300)
    from cron.job_run_details d2
    where d2.jobid = j.jobid and d2.status = 'failed'
    order by d2.start_time desc
    limit 1
  ) as latest_error,
  (
    select max(d3.start_time)
    from cron.job_run_details d3
    where d3.jobid = j.jobid and d3.status = 'failed'
  ) as latest_error_at,
  left(j.command, 200) as command
from cron.job j
left join cron.job_run_details d on d.jobid = j.jobid
group by j.jobid, j.jobname, j.schedule, j.active, j.command
order by runs_24h desc, j.jobid;
