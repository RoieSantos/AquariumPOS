-- STEP 2 of supabase_pancake_sync_wind_down.sql (the commented block there), as its own file.
-- Run AFTER supabase_item_master_cutover.sql, once both store POS PCs send WI- walk-ins
-- (supabase_check_disk_io_fix_status.sql section 4: 2026-10-24 both branches PANCAKE 0, only WI-).
--
-- Pauses the last Pancake order syncs - nothing new arrives through Pancake any more. These were
-- ~26.5 h of cron run time per day (sync-online-orders-from-pancake alone ~23.5 h).
--
-- Pausing keeps each job's command and schedule. Undo one with:
--   select cron.alter_job(jobid, active := true) from cron.job where jobname = '<job name>';
-- Safe to re-run.

select cron.alter_job(jobid, active := false)
from cron.job
where jobname in ('sync-online-orders-from-pancake',
                  'sync-online-order-details',
                  'sync-order-payments-from-pancake');

-- One result: every Pancake / online-order job and whether it still runs (all Pancake ones should be PAUSED).
select jobname::text, schedule::text, case when active then 'running' else 'PAUSED' end as state
from cron.job
where jobname ilike '%pancake%' or jobname ilike '%online-order%'
order by active desc, jobname;
