-- ONE-OFF: delete stray online order 1821 (To Ship, no Warehouse / Confirmed By / Created By)
-- and every portal row keyed on it. Run AFTER supabase_trace_online_order_1821.sql and checking
-- its output.
--
-- Aborts (nothing deleted) if the order ever posted stock to ItemLedgerEntries - ledger rows are
-- never deleted, so that case needs a reversing entry instead of a delete.
--
-- NOTE: this only removes the Supabase copy. If order 1821 still exists in Pancake and gets
-- updated there, the POS sync will push it back - delete/cancel it in Pancake too if it's real.
--
-- Safe to re-run (a second run just deletes 0 rows).

do $$
declare
  v_ledger int;
  v_deleted int;
begin
  select count(*) into v_ledger from public."ItemLedgerEntries" where "DocumentNo" = '1821';
  if v_ledger > 0 then
    raise exception 'Order 1821 has % ItemLedgerEntries row(s) - not deleting. Reverse the stock first.', v_ledger;
  end if;

  delete from public."DeliveryStops"               where "OrderID" = '1821';  -- FK to OnlineOrders
  delete from public."OnlineOrderLineReleases"     where "OrderID" = '1821';
  delete from public."OnlineOrderLineAttachments"  where "OrderID" = '1821';
  delete from public."OnlineOrderLinesRemoved"     where "OrderID" = '1821';
  delete from public."OnlineOrderLines"            where "OrderID" = '1821';
  delete from public."OnlineOrderAssignedMessages" where "OrderID" = '1821';
  delete from public."OnlineOrderStatusPhotos"     where "OrderID" = '1821';
  delete from public."OnlineOrderPayments"         where "OrderID" = '1821';
  delete from public."OnlineOrderPaymentScans"     where "OrderID" = '1821';
  delete from public."OnlineOrderProductionDone"   where "OrderID" = '1821';
  delete from public."OnlineOrderProductionRework" where "OrderID" = '1821';
  delete from public."OnlineOrderShipments"        where "OrderID" = '1821';
  delete from public."ItemLedgerOrderSync"         where "OrderID" = '1821';

  delete from public."OnlineOrders" where "OrderID" = '1821';
  get diagnostics v_deleted = row_count;
  raise notice 'Deleted % OnlineOrders row(s) for 1821.', v_deleted;
end $$;

-- Confirmation: should return 0.
select count(*) as remaining_order_1821 from public."OnlineOrders" where "OrderID" = '1821';
