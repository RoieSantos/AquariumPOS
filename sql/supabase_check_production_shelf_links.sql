-- Read-only check: Production Shelf Map shows "No racks at this location are linked to a product yet"
-- for Amaya. Per shelf: its warehouse, how many racks it has, how many are linked to an aquarium
-- (ItemCode set), and how many point at an item code that no longer exists in Items.
-- Also lists every warehouse whose name matches Amaya, in case the shelves sit on a different
-- Amaya warehouse ID than the one picked in the Location box.
-- Ends with ONE result.

select 'shelf' as section,
       sh."Id"::text as shelf_id,
       sh."Name"::text as shelf_name,
       sh."WarehouseId"::text as warehouse_id,
       w."Name"::text as warehouse_name,
       count(sp."Id") as racks,
       count(sp."Id") filter (where nullif(trim(coalesce(sp."ItemCode", '')), '') is not null) as racks_linked,
       count(sp."Id") filter (where nullif(trim(coalesce(sp."ItemCode", '')), '') is not null
                                and not exists (select 1 from public."Items" i where i."Code" = sp."ItemCode")) as linked_to_missing_item,
       string_agg(distinct sp."ItemCode", ', ') as item_codes
from public."ProductionShelves" sh
left join public."Warehouses" w on w."ID" = sh."WarehouseId"
left join public."ProductionShelfSpots" sp on sp."ShelfId" = sh."Id"
group by sh."Id", sh."Name", sh."WarehouseId", w."Name"

union all

select 'amaya warehouse', null, null, w."ID"::text, w."Name"::text,
       (select count(*) from public."ProductionShelves" sh where sh."WarehouseId" = w."ID"),
       null, null, null
from public."Warehouses" w
where w."Name" ilike '%amaya%'

order by 1 desc, 5, 3;
