-- READ-ONLY check: did the Disk IO fixes work, and is Pancake sync wind-down STEP 2 ready to run?
-- (Supabase "about to deplete its Disk IO Budget" banner seen again 2026-10-24. The banner can lag:
-- the budget only refills while usage stays under baseline.)
--
-- Changes nothing. One result: section / item / detail.
--   1 Cron state    - Pancake / online-order jobs: schedule, running or PAUSED (step 1 = 3 paused, 2 at */5)
--   2 Cron load     - total cron run time per hour, last 12 hours (was ~1.4 h per hour before step 1)
--   3 Top cron 24h  - the 8 jobs with the most run time in the last 24h
--   4 Walk-ins      - store sales per day / branch, last 3 days: PANCAKE (old POS build) vs WI- (new build).
--                     STEP 2 of supabase_pancake_sync_wind_down.sql is safe once BOTH branches show only WI-.
--   5 No-op trigger - zz_skip_noop_sync_update installed on each table (supabase_skip_noop_sync_updates.sql)

select '1 Cron state' as section, jobname::text as item,
       schedule::text || '; ' || case when active then 'running' else 'PAUSED' end as detail
from cron.job
where jobname ilike '%pancake%' or jobname ilike '%online-order%'

union all
select '2 Cron load', to_char(date_trunc('hour', d.start_time), 'YYYY-MM-DD HH24:00'),
       count(*) || ' runs; ' || date_trunc('second', sum(d.end_time - d.start_time))::text || ' total run time'
from cron.job_run_details d
where d.start_time > now() - interval '12 hours'
group by date_trunc('hour', d.start_time)

union all
select '3 Top cron 24h', x.jobname, x.detail
from (
  select j.jobname::text as jobname,
         count(*) || ' runs; ' || date_trunc('second', sum(d.end_time - d.start_time))::text || ' total; max '
         || date_trunc('second', max(d.end_time - d.start_time))::text || '; ' || j.schedule
         || case when j.active then '' else ' (now PAUSED)' end as detail
  from cron.job_run_details d
  join cron.job j on j.jobid = d.jobid
  where d.start_time > now() - interval '24 hours'
  group by j.jobname, j.schedule, j.active
  order by sum(d.end_time - d.start_time) desc nulls last
  limit 8
) x

union all
select '4 Walk-ins', o."Date"::text || ' branch ' || coalesce(o."LocationID", '?'),
       'PANCAKE ' || count(*) filter (where coalesce(o."Source", '') <> 'Portal')
       || ' / WI- ' || count(*) filter (where o."OrderID" like 'WI-%')
       || '; newest Pancake ' || coalesce(max(o."Time"::text) filter (where coalesce(o."Source", '') <> 'Portal'), '-')
from public."OnlineOrders" o
where o."Date" >= current_date - 2
  and (o."OrderID" like 'WI-%' or coalesce(o."Source", '') <> 'Portal')
group by o."Date", o."LocationID"

union all
select '5 No-op trigger', c.relname::text,
       case when exists (select 1 from pg_trigger t
                         where t.tgrelid = c.oid and t.tgname = 'zz_skip_noop_sync_update' and not t.tgisinternal)
            then 'installed' else 'MISSING' end
from pg_class c
join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
where c.relkind = 'r'
  and c.relname in ('Items', 'Variants', 'OnlineCustomers', 'AdvanceOrders', 'AdvanceOrderLines',
                    'AdvanceOrderPayments', 'OnlineOrderLines')

order by 1, 2;
