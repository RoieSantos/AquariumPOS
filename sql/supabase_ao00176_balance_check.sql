-- Read-only check: AO-00176 shows P599 due on the GMA Conversations order card but fully paid on
-- Online Orders. The card's Paid = sum(AutomatedOrderPayments); Online Orders shows
-- OnlineOrders.AmountPaid / Discount / Balance. This lists both sides plus every other payment
-- source (Pancake OnlineOrderPayments, Xendit, driver collections) so we can see which one has the
-- extra P599 that never reached AutomatedOrderPayments. Safe to re-run; one result.
with ao as (
  select * from public."AutomatedOrders" where "OrderNo" = 'AO-00176'
), ids as (
  select "OrderNo" as id from ao
  union select "PancakeReceiptNo" from ao where coalesce("PancakeReceiptNo", '') <> ''
)
select '1 AutomatedOrders' as section,
       jsonb_build_object('Status', "Status", 'EstimatedTotal', "EstimatedTotal", 'DeliveryFee', "DeliveryFee",
                          'PancakeReceiptNo', "PancakeReceiptNo", 'PancakeOrderId', "PancakeOrderId",
                          'CreatedAtUtc', "CreatedAtUtc")::text as detail
  from ao
union all
select '2 AutomatedOrderPayments (card Paid)',
       jsonb_build_object('PaymentId', "PaymentId", 'Amount', "Amount", 'Method', "Method", 'Reference', "Reference",
                          'RecordedBy', "RecordedBy", 'RecordedAtUtc', "RecordedAtUtc")::text
  from public."AutomatedOrderPayments" where "OrderNo" = 'AO-00176'
union all
select '3 OnlineOrders (Online Orders page)',
       jsonb_build_object('OrderID', "OrderID", 'Status', "Status", 'MoneyToCollect', "MoneyToCollect",
                          'AmountPaid', "AmountPaid", 'Discount', "Discount", 'Balance', "Balance",
                          'DeliveryFee', "DeliveryFee", 'Last_Updated_At', "Last_Updated_At")::text
  from public."OnlineOrders" where "OrderID" in (select id from ids)
union all
select '4 OnlineOrderPayments (Pancake sync)', to_jsonb(p)::text
  from public."OnlineOrderPayments" p where p."OrderID" in (select id from ids)
union all
select '5 XenditPayments', to_jsonb(x)::text
  from public."XenditPayments" x where exists (select 1 from ids where to_jsonb(x)::text like '%"' || ids.id || '"%')
union all
select '6 DeliveryCollections', to_jsonb(d)::text
  from public."DeliveryCollections" d where exists (select 1 from ids where to_jsonb(d)::text like '%"' || ids.id || '"%')
union all
-- Round 2: totals differ (AO 6436 vs Online Orders MoneyToCollect 5837 = exactly the 599 fee).
-- Line sums show which side holds the extra 599; stops show a combined-drop / pin fee change.
select '7 AO lines',
       jsonb_build_object('EntryNo', l."EntryNo", 'ItemName', l."ItemName", 'Qty', l."Quantity", 'Price', l."Price",
                          'LineTotal', l."Quantity" * l."Price")::text
  from public."AutomatedOrderLines" l where l."OrderNo" = 'AO-00176'
union all
select '7z AO lines SUM', jsonb_build_object('sum', coalesce(sum(l."Quantity" * l."Price"), 0))::text
  from public."AutomatedOrderLines" l where l."OrderNo" = 'AO-00176'
union all
select '8 Online Order lines',
       jsonb_build_object('LineID', l."LineID", 'Description', l."Description", 'Qty', l."Quantity", 'Price', l."Price",
                          'NetAmount', l."NetAmount")::text
  from public."OnlineOrderLines" l where l."OrderID" in (select id from ids)
union all
select '8z Online Order lines SUM', jsonb_build_object('sum', coalesce(sum(l."NetAmount"), 0))::text
  from public."OnlineOrderLines" l where l."OrderID" in (select id from ids)
union all
select '9 OnlineOrders fee/confirm',
       jsonb_build_object('PortalDeliveryFee', "PortalDeliveryFee", 'ConfirmedAtUtc', "ConfirmedAtUtc",
                          'ConfirmedBy', "ConfirmedBy", 'Source', "Source")::text
  from public."OnlineOrders" where "OrderID" in (select id from ids)
union all
select '10 DeliveryStops', to_jsonb(s)::text
  from public."DeliveryStops" s where exists (select 1 from ids where to_jsonb(s)::text like '%"' || ids.id || '"%')
order by 1;
