-- CHECK (read-only): which makers an online order needs, from the portal's synced OnlineOrderLines.
-- A line counts as a custom stand when (Description, ItemCode or product_display_id) contains "custom"
-- AND (Description or ItemCode) contains "stand" - same rule the Assign section uses
-- (admin_list_online_orders' has_stand_line). Aquarium is the same with "aquarium".
-- Change the order ID in both queries if checking another order.

-- 1. The saved lines. If CUSTOM-STAND isn't listed here, the sync hasn't saved it yet.
select l."LineID", l."ItemCode", l."Description", l."SyncedAtUtc",
       (l."Description" ilike '%custom%' or l."ItemCode" ilike '%custom%' or l."product_display_id" ilike '%custom%') as is_custom,
       (l."Description" ilike '%aquarium%' or l."ItemCode" ilike '%aquarium%') as mentions_aquarium,
       (l."Description" ilike '%stand%' or l."ItemCode" ilike '%stand%') as mentions_stand
from public."OnlineOrderLines" l
where l."OrderID" = '103949'
order by l."LineID";

-- 2. When the sync last re-read the order. Last_Updated_At (Pancake's edit time) newer than both
--    *CheckedAt times means the order is still waiting to be re-read.
select "OrderID", "Status", "ReceivedAtShop", "Last_Updated_At", "GlassThicknessCheckedAt", "NotePrintCheckedAt", "SyncedAtUtc"
from public."OnlineOrders"
where "OrderID" = '103949';
