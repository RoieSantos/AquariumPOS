-- Read-only check for order 105852 (Ready to Ship asked for 2 + 2 serials). Run a few minutes after
-- supabase_online_order_lines_block_pos_resurrect.sql, which queued the order to be re-read from Pancake.
--   - One 'line' row + one 'removed' row  = re-read happened, stale line gone - Ready to Ship asks for 2.
--   - Two 'line' rows with a NEW at_utc  = re-read happened but Pancake still returns two items.
--   - Two 'line' rows, at_utc still 2026-10-02 06:01 = not re-read yet (see the 'order' row: the check
--     timestamps are still empty until the sync gets to it).

select 'order' as kind, o."OrderID" as id, o."Status" as info,
       o."GlassThicknessCheckedAt" as checked_at, o."Last_Updated_At" as at_utc
from public."OnlineOrders" o where o."OrderID" = '105852'
union all
select 'line', l."LineID", l."ItemCode" || ' x ' || l."Quantity", null, l."SyncedAtUtc"
from public."OnlineOrderLines" l where l."OrderID" = '105852'
union all
select 'removed', r."LineID", null, null, r."RemovedAtUtc"
from public."OnlineOrderLinesRemoved" r where r."OrderID" = '105852'
order by 1, 2;
