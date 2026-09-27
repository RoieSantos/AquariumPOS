-- Read-only diagnostic: per item at Amaya, how many serials are IN_STOCK there (what the Transfer
-- Order serial picker offers) vs. what the Item Ledger says is on hand (what the pre-ship
-- "Cannot ship - not enough stock" check uses). Covers every Production Category item plus the
-- items from the blocked shipment (AQ-019, AQ-028, AST-013, S-014, S-003, S-012).
-- Change the warehouse name in the first CTE to check another location.

with wh as (
  select "ID" as wh_id, "Name" as wh_name from public."Warehouses" where "Name" = 'Amaya'
),
items as (
  select i."Code", i."Name", i."CategoryCode"
  from public."Items" i
  left join public."Categories" c on c."Code" = i."CategoryCode"
  where coalesce(c."IsProductionCategory", false)
     or i."Code" in ('AQ-019', 'AQ-028', 'AST-013', 'S-014', 'S-003', 'S-012')
),
serials as (
  select s."ItemCode",
         count(*) filter (where s."Status" = 'IN_STOCK')   as serials_in_stock,
         count(*) filter (where s."Status" = 'IN_TRANSIT') as serials_in_transit_to_amaya
  from public."ItemSerialTracking" s, wh
  where s."Location" = wh.wh_name
  group by s."ItemCode"
),
ledger as (
  select e."ItemCode", sum(e."Quantity") as ledger_on_hand
  from public."ItemLedgerEntries" e, wh
  where e."WarehouseId" = wh.wh_id
  group by e."ItemCode"
)
select it."Code"                                  as item_code,
       it."Name"                                  as item_name,
       it."CategoryCode"                          as category,
       coalesce(s.serials_in_stock, 0)            as serials_in_stock_at_amaya,
       coalesce(l.ledger_on_hand, 0)              as ledger_on_hand_at_amaya,
       coalesce(s.serials_in_stock, 0) - coalesce(l.ledger_on_hand, 0) as difference,
       coalesce(s.serials_in_transit_to_amaya, 0) as serials_in_transit_to_amaya
from items it
left join serials s on s."ItemCode" = it."Code"
left join ledger l on l."ItemCode" = it."Code"
where coalesce(s.serials_in_stock, 0) <> 0 or coalesce(l.ledger_on_hand, 0) <> 0
   or it."Code" in ('AQ-019', 'AQ-028', 'AST-013', 'S-014', 'S-003', 'S-012')
order by (coalesce(s.serials_in_stock, 0) - coalesce(l.ledger_on_hand, 0)) desc, it."Code";
