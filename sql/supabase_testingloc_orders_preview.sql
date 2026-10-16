-- Read-only preview for supabase_testingloc_orders_delete.sql - per "create a sql query that will remove
-- all TESTINGLOC warehouse order". Lists what the delete would touch; changes nothing.
--
--   order   - every Online / Walk-in order whose warehouse is TESTINGLOC (by Warehouses.Name or LocationID)
--   ledger  - its Item Ledger 'Sales Order' entries (these get deleted, then item quantities recomputed)
--   serial  - serials sold against it: at TESTINGLOC -> deleted; anywhere else -> back to IN_STOCK, unlinked
--   summary - totals
--
-- Check the order list is ONLY test orders before running the delete.

with test_orders as (
  select o."OrderID", o."CustomerName", o."Status", o."ReceivedAtShop", o."Date" as "OrderDate",
         coalesce(w."Name", o."LocationID") as warehouse
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where upper(trim(coalesce(w."Name", ''))) = 'TESTINGLOC'
     or upper(trim(coalesce(o."LocationID", ''))) = 'TESTINGLOC'
),
test_wh as (
  select w."ID"::text as id, w."Name" as name from public."Warehouses" w
  where upper(trim(coalesce(w."Name", ''))) = 'TESTINGLOC' or upper(trim(w."ID"::text)) = 'TESTINGLOC'
),
ledger as (
  select e."DocumentNo" as order_id, count(*) as entries, sum(e."Quantity") as qty
  from public."ItemLedgerEntries" e
  where e."DocumentType" = 'Sales Order' and e."DocumentNo" in (select "OrderID" from test_orders)
  group by e."DocumentNo"
),
serials as (
  select s."SoldOnlineOrderId" as order_id, s."SerialNo", s."ItemCode", s."Status", s."Location",
         exists (select 1 from test_wh t where upper(trim(coalesce(s."Location", ''))) in (upper(t.id), upper(t.name))) as at_test
  from public."ItemSerialTracking" s
  where s."SoldOnlineOrderId" in (select "OrderID" from test_orders)
)
select 'order' as section, t."OrderID" as order_id,
       format('%s | %s | %s | %s | %s', coalesce(t."CustomerName", '-'), coalesce(t."Status", '-'),
              case when t."ReceivedAtShop" then 'walk-in' else 'online' end, coalesce(t."OrderDate"::text, '-'), t.warehouse) as detail
from test_orders t
union all
select 'ledger', l.order_id, format('%s Sales Order entr%s, qty %s - will be DELETED', l.entries,
       case when l.entries = 1 then 'y' else 'ies' end, l.qty)
from ledger l
union all
select 'serial', s.order_id, format('%s (%s) %s @ %s - %s', s."SerialNo", s."ItemCode", s."Status", coalesce(s."Location", '-'),
       case when s.at_test then 'will be DELETED (TESTINGLOC serial)' else 'back to IN_STOCK, unlinked' end)
from serials s
union all
select 'summary', null,
       format('%s order(s) | %s ledger entr(ies) | %s serial(s) | TESTINGLOC warehouse found: %s',
              (select count(*) from test_orders), coalesce((select sum(entries) from ledger), 0),
              (select count(*) from serials), (select coalesce(string_agg(id || ' = ' || coalesce(name, '?'), ', '), 'NO') from test_wh))
order by section, order_id;
