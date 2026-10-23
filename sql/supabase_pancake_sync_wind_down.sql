-- Wind down the Pancake sync crons - they were ~34 h of database time a day and most of the Disk IO
-- budget (supabase_diagnose_disk_io.sql, 2026-10-23). supabase_check_pancake_still_used.sql showed the
-- only thing still arriving through Pancake is POS walk-in sales from store PCs on the pre-2026-10-22
-- POS build (the new build writes WI- walk-ins straight to the portal). Old Pancake orders are all
-- Shipped / canceled / Delivered or untouched since September; Order Now and bot / GMA orders are
-- portal-only.
--
-- STEP 1 (now):
--   * PAUSE refresh-open-online-order-statuses - no open Pancake order is still moving.
--   * PAUSE sync-online-customers-from-pancake - walk-ins are all "POS WALKIN ORDERS"; the portal
--     keeps its own customers (old Pancake customers stay as they are).
--   * PAUSE sync-payment-methods-from-pancake  - payment methods are kept in the portal.
--   * SLOW  sync-online-orders-from-pancake and sync-online-order-details to every 5 minutes (was every
--     minute). Still needed while the stores send walk-ins to Pancake: they bring the sale + its lines
--     into the portal (dashboard walk-in sales, item ledger stock). A store sale can now take up to
--     ~5 min to show in the portal.
--   * sync-order-payments-from-pancake and sync-items-from-pancake stay as they are (every 5 min).
--   * Resets the query stats so the next supabase_diagnose_disk_io.sql shows only the new usage.
--
-- STEP 2 (only after BOTH store POS PCs run the new build - new store sales show as WI- orders): run the
-- commented block at the bottom.
--
-- Pausing keeps each job's command and schedule. Undo one with:
--   select cron.alter_job(jobid, active := true) from cron.job where jobname = '<job name>';
--   select cron.alter_job(jobid, schedule := '* * * * *') from cron.job where jobname = '<job name>';
-- Safe to re-run.

select cron.alter_job(jobid, active := false)
from cron.job
where jobname in ('refresh-open-online-order-statuses',
                  'sync-online-customers-from-pancake',
                  'sync-payment-methods-from-pancake');

select cron.alter_job(jobid, schedule := '*/5 * * * *')
from cron.job
where jobname in ('sync-online-orders-from-pancake', 'sync-online-order-details');

do $$
begin
  perform extensions.pg_stat_statements_reset();
exception when others then
  raise notice 'Could not reset query stats (%): the next disk check will still include older numbers.', sqlerrm;
end;
$$;

-- STEP 2 - after both store PCs are on the new POS build. Remove the /* */ and run:
/*
select cron.alter_job(jobid, active := false)
from cron.job
where jobname in ('sync-online-orders-from-pancake',
                  'sync-online-order-details',
                  'sync-order-payments-from-pancake');
*/

-- One result: every job with Pancake / online-order sync in it, its schedule and whether it runs.
select jobname::text, schedule::text, case when active then 'running' else 'PAUSED' end as state
from cron.job
where jobname ilike '%pancake%' or jobname ilike '%online-order%'
order by active desc, jobname;
