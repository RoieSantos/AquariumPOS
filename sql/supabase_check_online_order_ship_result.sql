-- Diagnostic: did a "Ready to Ship" that showed "Failed to fetch" in the browser actually go through?
-- "Failed to fetch" means the browser never got a response (connection dropped / gateway timeout while
-- the RPC was waiting on Pancake), so the server may have finished the change anyway.
-- Replace ORDER_ID_HERE with the order's ID, then run in the Supabase SQL editor. Read-only.

-- 1) Current status of the order in the portal (To Ship = it went through; Confirmed/Printed = it didn't).
select o."OrderID", o."Status", o."LocationID"
from public."OnlineOrders" o
where o."OrderID" = 'ORDER_ID_HERE';

-- 2) Serials claimed for the order (rows here = serials were marked SOLD to it).
select s."SerialNo", s."ItemCode", s."VariantCode", s."Status", s."Location", s."UpdatedAtUtc"
from public."ItemSerialTracking" s
where s."SoldOnlineOrderId" = 'ORDER_ID_HERE'
order by s."UpdatedAtUtc" desc;

-- 3) Production order linked to it by "Assign" (if any).
select po."No", po."Status", po."CreatedAtUtc"
from public."ProductionOrders" po
where po."SourceOnlineOrderId" = 'ORDER_ID_HERE'
order by po."CreatedAtUtc" desc;

-- 4) Anything running or stuck RIGHT NOW on online orders (run while / right after it fails).
--    wait_event_type = 'Lock' + blocked_by = another pid -> the order row is locked by that pid
--    (e.g. a background Pancake sync or an earlier Ready to Ship attempt still running).
select a.pid, now() - a.query_start as running_for, a.state, a.wait_event_type, a.wait_event,
       pg_blocking_pids(a.pid) as blocked_by, left(a.query, 200) as query
from pg_stat_activity a
where a.datname = current_database()
  and a.pid <> pg_backend_pid()
  and a.state <> 'idle'
order by a.query_start;
