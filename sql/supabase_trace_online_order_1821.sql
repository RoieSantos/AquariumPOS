-- READ-ONLY trace of online order 1821 (shows in Online Orders > To Ship with no Warehouse /
-- Confirmed By / Created By). Lists the order header plus how many rows every table keyed on
-- OrderID holds for it, so we know what a delete has to clean up. Safe to re-run.

with o as (
  select * from public."OnlineOrders" where "OrderID" = '1821'
)
select 'OnlineOrders (header)' as section,
       (select count(*) from o)::text as row_count,
       (select concat_ws(' | ',
          'Date=' || "Date", 'Time=' || "Time", 'Status=' || "Status", 'Customer=' || "CustomerName",
          'LocationID=' || coalesce("LocationID"::text, '(null)'), 'CreatedBy=' || coalesce("CreatedBy", '(null)'),
          'ConfirmedBy=' || coalesce("ConfirmedBy", '(null)'), 'MoneyToCollect=' || "MoneyToCollect",
          'ReceivedAtShop=' || coalesce("ReceivedAtShop"::text, '(null)'),
          'LastUpdated=' || "Last_Updated_At", 'SyncedAtUtc=' || "SyncedAtUtc")
        from o) as detail
union all select 'OnlineOrderLines', count(*)::text,
       string_agg(coalesce("ItemCode", '') || ' x' || coalesce("Quantity"::text, '?') || ' ' || coalesce("Description", ''), '; ')
  from public."OnlineOrderLines" where "OrderID" = '1821'
union all select 'OnlineOrderLinesRemoved', count(*)::text, null from public."OnlineOrderLinesRemoved" where "OrderID" = '1821'
union all select 'OnlineOrderLineReleases', count(*)::text, null from public."OnlineOrderLineReleases" where "OrderID" = '1821'
union all select 'OnlineOrderLineAttachments', count(*)::text, null from public."OnlineOrderLineAttachments" where "OrderID" = '1821'
union all select 'OnlineOrderAssignedMessages', count(*)::text, null from public."OnlineOrderAssignedMessages" where "OrderID" = '1821'
union all select 'OnlineOrderStatusPhotos', count(*)::text, null from public."OnlineOrderStatusPhotos" where "OrderID" = '1821'
union all select 'OnlineOrderPayments', count(*)::text, null from public."OnlineOrderPayments" where "OrderID" = '1821'
union all select 'OnlineOrderPaymentScans', count(*)::text, null from public."OnlineOrderPaymentScans" where "OrderID" = '1821'
union all select 'OnlineOrderProductionDone', count(*)::text, null from public."OnlineOrderProductionDone" where "OrderID" = '1821'
union all select 'OnlineOrderProductionRework', count(*)::text, null from public."OnlineOrderProductionRework" where "OrderID" = '1821'
union all select 'OnlineOrderShipments', count(*)::text, null from public."OnlineOrderShipments" where "OrderID" = '1821'
union all select 'DeliveryStops (FK)', count(*)::text, null from public."DeliveryStops" where "OrderID" = '1821'
union all select 'ItemLedgerOrderSync', count(*)::text, max("LastError") from public."ItemLedgerOrderSync" where "OrderID" = '1821'
union all select 'ItemLedgerEntries (stock posted!)', count(*)::text,
       string_agg("EntryType" || ' ' || "ItemCode" || ' ' || "Quantity" || ' @' || "WarehouseId", '; ')
  from public."ItemLedgerEntries" where "DocumentNo" = '1821'
union all select 'AutomatedOrders (receipt link)', count(*)::text, string_agg("OrderNo"::text, ', ')
  from public."AutomatedOrders" where "PancakeReceiptNo" = '1821';
