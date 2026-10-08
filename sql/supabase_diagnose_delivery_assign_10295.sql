-- READ-ONLY: why can't order 10295 be assigned on the Delivery calendar?
-- Safe to re-run. Changes no data. Run the WHOLE file - one result.
--
-- The Delivery calendar's "Assign Order" list (admin_list_deliverable_online_orders) only shows rows
-- from public."OnlineOrders" with ForDelivery not true and Status in Confirmed/Printed/To Ship/Shipped
-- (Cancelled for super users). DeliveryStops.OrderID is a foreign key to OnlineOrders, so a POS
-- Advance Order (public."AdvanceOrders") can't be a delivery stop unless it also exists in OnlineOrders.

select * from (
  select '1 OnlineOrders' as section, o."OrderID"::text as id,
         concat_ws(' | ', 'Status=' || o."Status", 'ForDelivery=' || coalesce(o."ForDelivery"::text, 'null'),
                   'ReceivedAtShop=' || coalesce(o."ReceivedAtShop"::text, 'null'), 'Customer=' || o."CustomerName") as detail
  from public."OnlineOrders" o
  where o."OrderID" ilike '%10295%'
  union all
  select '2 AdvanceOrders', a."TransactionNo"::text,
         concat_ws(' | ', 'ReceiptNo=' || a."ReceiptNo", 'Date=' || a."Date", 'Customer=' || a."CustomerName",
                   'Balance=' || a."Balance", 'Desc=' || left(a."Order_Description", 120))
  from public."AdvanceOrders" a
  where a."TransactionNo" ilike '%10295%' or a."ReceiptNo" ilike '%10295%'
  union all
  select '3 DeliveryStops', s."OrderID"::text, 'Already scheduled on ' || s."DeliveryDate"
  from public."DeliveryStops" s
  where s."OrderID" ilike '%10295%'
  union all
  select '4 AutomatedOrders', ao."OrderNo"::text, 'PancakeReceiptNo=' || coalesce(ao."PancakeReceiptNo"::text, 'null')
  from public."AutomatedOrders" ao
  where ao."OrderNo"::text ilike '%10295%' or ao."PancakeReceiptNo"::text ilike '%10295%'
) r
order by section, id;
