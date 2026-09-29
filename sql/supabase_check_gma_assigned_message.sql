-- Diagnostic: why order 104607's "in production" message went down the Pancake route ("Order is missing
-- Page_ID/Conversation_ID") instead of the GMA Page route (supabase_online_order_assigned_message_gma.sql).

-- 1. Is the GMA version of admin_sync_online_order_assigned_status installed? Expect has_gma_route = true.
--    false = supabase_online_order_assigned_message_gma.sql hasn't been run yet.
select position('gma_psid' in pg_get_function_result(p.oid)) > 0 as has_gma_route
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_sync_online_order_assigned_status';

-- 2. Is 104607 linked to a GMA conversation? Expect one row with a GmaPsid.
--    No row = the order wasn't created from GMA Conversations (or PancakeReceiptNo wasn't saved).
select "OrderNo", "PancakeReceiptNo", "GmaPsid", "PancakeSyncStatus"
from public."AutomatedOrders"
where "PancakeReceiptNo" = '104607';

-- 3. What the message log recorded for it.
select * from public."OnlineOrderAssignedMessages" where "OrderID" = '104607';
