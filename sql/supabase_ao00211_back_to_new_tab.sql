-- One-off: bring Order Now order AO-00211 (Ralph Lubaton) back to Online Orders -> New.
-- It was pushed to Pancake (order 118462) because the live submit_automated_order / public_sync_automated_order_to_pancake /
-- cron_process_pending_automated_orders had lost their portal-only versions (supabase_check_ao00211_missing.sql
-- showed all three reverted). Pancake is retired, so the order belongs in the portal like every other AO- order.
--
-- Run AFTER supabase_order_now_portal_only.sql (and supabase_order_now_line_notes.sql), so nothing pushes it again.
-- Clears the Pancake link and marks it 'Not Pushed' / 'Order Now' - the New tab lists it and staff Confirm Order.
-- Only touches AO-00211 while it's still linked to Pancake 118462 and not yet in Online Orders, so it's safe to re-run.
-- Cancel / delete order 118462 in Pancake by hand - this file does not touch Pancake.
-- Ends with one result query.

update public."AutomatedOrders"
   set "PancakeSyncStatus" = 'Not Pushed',
       "PancakeOrderId" = null,
       "PancakeSyncError" = null,
       "UpdatedBy" = 'Order Now'
 where "OrderNo" = 'AO-00211'
   and "PancakeOrderId"::text = '118462'
   and coalesce("Status", '') not in ('Cancelled', 'Completed')
   and not exists (select 1 from public."OnlineOrders" oo where oo."OrderID" = 'AO-00211');

select o."OrderNo", o."Status", o."PancakeSyncStatus", o."PancakeOrderId", o."UpdatedBy",
       (o."PancakeSyncStatus" = 'Not Pushed' and coalesce(o."Status", '') not in ('Cancelled', 'Completed')) as on_new_tab
from public."AutomatedOrders" o
where o."OrderNo" = 'AO-00211';
