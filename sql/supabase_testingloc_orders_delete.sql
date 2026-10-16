-- One-off cleanup, per "create a sql query that will remove all TESTINGLOC warehouse order": deletes
-- every Online / Walk-in order whose warehouse is TESTINGLOC (Warehouses.Name or LocationID).
--
-- Run supabase_testingloc_orders_preview.sql FIRST and check it lists only test orders.
-- Run this whole file at once - it is one transaction, so any failure rolls everything back.
--
-- Per order:
--   1. Item Ledger 'Sales Order' entries for it are deleted. ItemLedgerEntries is append-only, so - same
--      escape hatch as supabase_item_ledger_delete_0813pm_seed.sql - the two guard triggers are disabled
--      for the delete and re-enabled, then Items."QuantityInStock" is recomputed (_ile_sync_all_item_quantities).
--   2. Serials sold against it: a TESTINGLOC serial is deleted; one from any other location goes back to
--      IN_STOCK with its sold link cleared.
--   3. _delete_online_order_core (supabase_online_order_admin_delete.sql) - removes the order and every
--      portal row keyed on it (lines, photos, payments, delivery stops + collections, ...) and records it in
--      OnlineOrdersDeleted so the POS / Pancake sync can't bring it back.
-- Ends with one result: each order and whether it was deleted.
--
-- Run AFTER supabase_online_order_admin_delete.sql (already live - it backs the Delete Order button).
-- Safe to re-run: a second run finds nothing left to delete.

drop table if exists _testingloc_out;

begin;

create temp table _testingloc_orders on commit drop as
select o."OrderID" as order_id
from public."OnlineOrders" o
left join public."Warehouses" w on w."ID" = o."LocationID"
where upper(trim(coalesce(w."Name", ''))) = 'TESTINGLOC'
   or upper(trim(coalesce(o."LocationID", ''))) = 'TESTINGLOC';

create temp table _testingloc_result (order_id text, deleted boolean, message text) on commit drop;

-- 1. Item Ledger entries.
alter table public."ItemLedgerEntries" disable trigger "TR_ItemLedgerEntries_NoUpdateDelete";
alter table public."ItemLedgerEntries" disable trigger "TR_ItemLedgerEntries_NoTruncate";

-- A kept reversing entry pointing at one about to go would block the delete - clear that pointer.
update public."ItemLedgerEntries" k
   set "ReversesEntryNo" = null
 where k."ReversesEntryNo" in (
         select e."EntryNo" from public."ItemLedgerEntries" e
         where e."DocumentType" = 'Sales Order' and e."DocumentNo" in (select order_id from _testingloc_orders))
   and not (k."DocumentType" = 'Sales Order' and k."DocumentNo" in (select order_id from _testingloc_orders));

delete from public."ItemLedgerEntries" e
 where e."DocumentType" = 'Sales Order' and e."DocumentNo" in (select order_id from _testingloc_orders);

alter table public."ItemLedgerEntries" enable trigger "TR_ItemLedgerEntries_NoUpdateDelete";
alter table public."ItemLedgerEntries" enable trigger "TR_ItemLedgerEntries_NoTruncate";

-- 2. Serials.
delete from public."ItemSerialTracking" s
 where s."SoldOnlineOrderId" in (select order_id from _testingloc_orders)
   and exists (select 1 from public."Warehouses" w
               where (upper(trim(coalesce(w."Name", ''))) = 'TESTINGLOC' or upper(trim(w."ID"::text)) = 'TESTINGLOC')
                 and upper(trim(coalesce(s."Location", ''))) in (upper(trim(w."ID"::text)), upper(trim(coalesce(w."Name", '')))));

update public."ItemSerialTracking" s
   set "Status" = 'IN_STOCK', "SoldOnlineOrderId" = null, "SoldReceiptNo" = null, "UpdatedAtUtc" = now()
 where s."SoldOnlineOrderId" in (select order_id from _testingloc_orders);

-- 3. The orders themselves - each in its own sub-transaction, so one refusal doesn't stop the rest.
do $$
declare
  v_id text;
begin
  for v_id in select order_id from _testingloc_orders order by order_id loop
    begin
      perform public._delete_online_order_core(v_id, 'cleanup: TESTINGLOC');
      insert into _testingloc_result values (v_id, true, null);
    exception when others then
      insert into _testingloc_result values (v_id, false, sqlerrm);
    end;
  end loop;
end;
$$;

-- Items."QuantityInStock" follows the ledger via an INSERT trigger, which a DELETE never fires.
select public._ile_sync_all_item_quantities();

-- Result (the editor shows this last statement's rows - captured before COMMIT drops the temp table).
create temp table _testingloc_out as
select order_id, deleted, coalesce(message, 'Deleted') as message from _testingloc_result
union all
select '(total)', null, format('%s deleted, %s refused',
       (select count(*) from _testingloc_result where deleted), (select count(*) from _testingloc_result where not deleted));

commit;

select * from _testingloc_out order by deleted nulls last, order_id;
