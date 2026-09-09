-- One-off diagnostic for "AutomatedOrders row was created but the Pancake order never was, and
-- PancakeSyncStatus is stuck at Pending" - checks the three things that have to all be working for
-- the async push pipeline (see supabase_automated_order_async_pancake_sync.sql) to ever advance a
-- Pending order to Synced/Failed:
--   1) Does the safety-net cron job even exist, and has it actually been running?
--   2) What do the stuck orders' own sync/error columns say right now?
--   3) Manually trigger the push for ONE stuck order and see the real result/error immediately,
--      instead of waiting on cron or guessing.
--
-- Safe to re-run. Step 3 DOES have a side effect (it will actually push that one order to Pancake
-- if nothing's stopping it) - only uncomment/run it for an order you actually want pushed now.

-- 1) Does the cron job exist, and when did it last run?
select jobid, jobname, schedule, active
from cron.job
where jobname = 'process-pending-automated-orders';

select jobid, runid, status, return_message, start_time, end_time
from cron.job_run_details
where jobid = (select jobid from cron.job where jobname = 'process-pending-automated-orders')
order by start_time desc
limit 10;

-- 2) What do the stuck orders themselves say right now?
select "OrderNo", "Status", "PancakeSyncStatus", "PancakeSyncError", "PancakeOrderId",
       "ConfirmationMessageStatus", "ConfirmationMessageError", "CreatedAtUtc"
from public."AutomatedOrders"
where "PancakeSyncStatus" = 'Pending'
order by "CreatedAtUtc" desc
limit 20;

-- 3) Manually trigger the push for ONE specific stuck order (swap in a real OrderNo below), then
-- re-select it to see exactly what happened - a real HTTP error, an item-matching failure, etc.,
-- instead of the silent .catch(() => {}) the browser's own fire-and-forget call swallows.
-- select public.public_sync_automated_order_to_pancake('AO-00043');
-- select "OrderNo", "PancakeSyncStatus", "PancakeSyncError", "PancakeOrderId" from public."AutomatedOrders" where "OrderNo" = 'AO-00043';
