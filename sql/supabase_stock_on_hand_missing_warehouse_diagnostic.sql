-- Diagnostic (read-only): which items on Stock On Hand are missing a cache row for a specific
-- warehouse, even though they have rows for other warehouses (e.g. "shows Amaya/GMA but never
-- Warehouse"). Confirms whether that's a real Pancake data gap (no variations_warehouses entry
-- for that warehouse on that product) rather than a bug in the category-sync/refresh flow.
--
-- Run in the Supabase SQL editor. Change v_target_warehouse below to the exact Warehouses."Name"
-- you're checking (must match Warehouse Setup exactly, case-sensitive).

with target as (
  select "ID" as warehouse_id
  from public."Warehouses"
  where "Name" = 'Warehouse'  -- <-- change this to the warehouse name you're checking
)
select
  c."ItemCode",
  c."ItemName",
  c."CategoryCode",
  string_agg(distinct w."Name", ', ' order by w."Name") as present_in_warehouses
from public."ItemWarehouseStockCache" c
left join public."Warehouses" w on w."ID" = c."WarehouseId"
group by c."ItemCode", c."ItemName", c."CategoryCode"
having not bool_or(c."WarehouseId" = (select warehouse_id from target))
order by c."ItemName";
