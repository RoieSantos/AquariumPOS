-- Re-pull Pancake orders into Online Orders (public."OnlineOrders" + "OnlineOrderLines") for a date range -
-- per "is there a way we can resync all the orders? ... orders from pancake going to online orders".
--
-- HOW THE SYNC WORKS (nothing new is installed here - this only re-points the existing cron jobs):
--   * sync-online-orders-from-pancake (every minute, cron_sync_online_orders_from_pancake - see
--     supabase_online_order_sync_edited_lines.sql) asks Pancake only for orders updated AFTER a saved
--     cursor, PancakeSyncState "/orders". Rewinding that cursor makes the next run re-read every order
--     updated since then and upsert its header (status, customer, totals, dates...). Up to 10,000 orders
--     per run (100 pages x 100).
--   * sync-online-order-details (every minute, cron_sync_online_order_details) re-reads an order's lines /
--     glass thickness / print note whenever its GlassThicknessCheckedAt is empty. Clearing it re-queues the
--     order - 60 per minute, newest first.
--
-- Safe to run any time: upserts only (nothing is deleted or duplicated), no table locks, the cursor
-- only ever moves forward again from where you set it.
--
-- Run step 1 (pick your date), then check with step 3 over the next few minutes. Step 2 only if you also
-- want the item lines re-read (e.g. items edited in Pancake that never showed up on the portal).

-- ---------------------------------------------------------------------------
-- 0. Where the cursor is now (the last Pancake "updated at" the sync has seen).
select "Entity", "LastSyncUtc", "LastSyncUtc" at time zone 'Asia/Manila' as last_sync_manila
from public."PancakeSyncState"
where "Entity" = '/orders';

-- ---------------------------------------------------------------------------
-- 1. Rewind the cursor - change '7 days' to how far back you want to re-pull (e.g. '30 days').
--    Keep it to what you need: a wider window just takes the first cron run longer.
update public."PancakeSyncState"
set "LastSyncUtc" = now() - interval '7 days'
where "Entity" = '/orders';

-- ---------------------------------------------------------------------------
-- 2. (Optional) Also re-read the item lines / glass / print note of orders in the same window.
--    Same '7 days' as step 1. ~60 orders per minute, so e.g. 600 orders take ~10 minutes.
update public."OnlineOrders"
set "GlassThicknessCheckedAt" = null
where "Date" >= ((now() at time zone 'Asia/Manila')::date - 7);

-- ---------------------------------------------------------------------------
-- 3. PROGRESS - re-run every minute or two.
--    cursor_manila should jump back toward "now" after the next header run (~1 minute).
--    lines_still_queued counts down to 0 as the details job works through step 2.
select
  (select "LastSyncUtc" at time zone 'Asia/Manila' from public."PancakeSyncState" where "Entity" = '/orders') as cursor_manila,
  (select max("SyncedAtUtc") at time zone 'Asia/Manila' from public."OnlineOrders") as last_header_write_manila,
  (select count(*) from public."OnlineOrders"
    where "Date" >= ((now() at time zone 'Asia/Manila')::date - 7) and "GlassThicknessCheckedAt" is null) as lines_still_queued,
  (select count(*) from public."OnlineOrders"
    where nullif(trim(coalesce("Status", '')), '') is null) as stub_rows_without_status;

-- Did the cron runs succeed? (errors show here, e.g. a Pancake HTTP failure)
select j.jobname, d.status, d.return_message, d.start_time at time zone 'Asia/Manila' as started_manila
from cron.job_run_details d
join cron.job j on j.jobid = d.jobid
where j.jobname in ('sync-online-orders-from-pancake', 'sync-online-order-details')
order by d.start_time desc
limit 10;
