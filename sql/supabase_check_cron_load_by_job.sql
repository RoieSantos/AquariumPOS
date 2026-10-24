-- READ-ONLY check: which cron job is still using ~1 h of database time every hour after Pancake sync
-- wind-down step 1? (supabase_check_disk_io_fix_status.sql, 2026-10-24: ~280 runs / 1h06 run time per
-- hour, and sync-online-orders-from-pancake showed 1334 runs / 23h56 in 24h although it is set to */5 -
-- i.e. it still looks like it runs every minute.)
--
-- Changes nothing. One result: section / item / detail.
--   1 Last 6h per job - runs, total / avg / max time, runs per hour, and the real gap between starts
--                       (a */5 job should show ~12 runs/h and a 5-minute gap)
--   2 Last 10 runs    - start time, duration and status of the 10 newest sync-online-orders-from-pancake runs
--   3 Job setup       - schedule, active, and the exact command of each Pancake / online-order job

with runs as (
  select j.jobname::text as jobname, j.schedule::text as schedule, d.start_time, d.end_time, d.status,
         d.start_time - lag(d.start_time) over (partition by d.jobid order by d.start_time) as gap
  from cron.job_run_details d
  join cron.job j on j.jobid = d.jobid
  where d.start_time > now() - interval '6 hours'
)

select '1 Last 6h per job' as section, jobname as item,
       count(*) || ' runs (' || round(count(*) / 6.0, 1) || '/h); total '
       || date_trunc('second', sum(end_time - start_time))::text || '; avg '
       || date_trunc('second', avg(end_time - start_time))::text || '; max '
       || date_trunc('second', max(end_time - start_time))::text || '; typical gap '
       || coalesce(date_trunc('second', percentile_cont(0.5) within group (order by gap))::text, '-')
       || '; failed ' || count(*) filter (where status = 'failed') || '; schedule ' || max(schedule) as detail
from runs
group by jobname

union all
select '2 Last 10 runs', x.started, x.detail
from (
  select to_char(d.start_time, 'YYYY-MM-DD HH24:MI:SS') as started,
         coalesce(date_trunc('second', d.end_time - d.start_time)::text, 'still running') || '; ' || d.status
         || coalesce('; ' || left(nullif(d.return_message, ''), 80), '') as detail
  from cron.job_run_details d
  join cron.job j on j.jobid = d.jobid
  where j.jobname = 'sync-online-orders-from-pancake'
  order by d.start_time desc
  limit 10
) x

union all
select '3 Job setup', jobname::text,
       'jobid ' || jobid || '; ' || schedule || '; ' || case when active then 'running' else 'PAUSED' end
       || '; ' || regexp_replace(left(command, 160), '\s+', ' ', 'g')
from cron.job
where jobname ilike '%pancake%' or jobname ilike '%online-order%'

order by 1, 2 desc;
