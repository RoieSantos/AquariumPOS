-- Bot orders show "Vic" (Messenger) or "Alice" (website) as the Sales Staff instead of "AI Bot",
-- per "i want it to be named as Vic". New orders already save the name (chatbot-engine.ts
-- botStaffName); this renames the existing ones. Safe to re-run (only touches 'AI Bot' rows).
--
-- Receipts: public_get_automated_order_receipt still maps 'AI Bot' to 'Online Assistant', but no row
-- keeps 'AI Bot' after this, so they fall through to the saved name ("Vic") - no function change needed.

-- Online Orders (OrderID = the AO number for portal-confirmed bot orders).
update public."OnlineOrders" oo
set "CreatedBy" = case when ao."GmaPsid" like 'web:%' then 'Alice' else 'Vic' end
from public."AutomatedOrders" ao
where oo."CreatedBy" = 'AI Bot'
  and ao."OrderNo" = oo."OrderID";

update public."OnlineOrders"
set "CreatedBy" = 'Vic'
where "CreatedBy" = 'AI Bot';

-- Bot drafts not yet confirmed (confirming replaces UpdatedBy with the staff username).
update public."AutomatedOrders"
set "UpdatedBy" = case when "GmaPsid" like 'web:%' then 'Alice' else 'Vic' end
where "UpdatedBy" = 'AI Bot';

update public."ChatbotLocationRequests"
set "RequestedBy" = 'Vic'
where "RequestedBy" = 'AI Bot';

-- Check: should be 0 everywhere.
select 'OnlineOrders still AI Bot' as section, count(*) as rows from public."OnlineOrders" where "CreatedBy" = 'AI Bot'
union all
select 'AutomatedOrders still AI Bot', count(*) from public."AutomatedOrders" where "UpdatedBy" = 'AI Bot'
union all
select 'OnlineOrders now Vic/Alice', count(*) from public."OnlineOrders" where "CreatedBy" in ('Vic', 'Alice');
