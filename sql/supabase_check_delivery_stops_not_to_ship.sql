-- Read-only: delivery stops from today on whose order hasn't been through To Ship yet - the ones
-- supabase_delivery_receipt_serial_gate.sql will refuse to print a Delivery Receipt / Invoice for, so they
-- can be fixed (To Ship on Online Orders) before the delivery day. Changes nothing. Run AFTER
-- supabase_delivery_receipt_serial_gate.sql (uses its _order_status_past_to_ship).

select s."DeliveryDate" as delivery_date,
       coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo") as order_id,
       case when s."AutomatedOrderNo" is not null then 'Draft AO - not confirmed'
            when s."AdvanceTransactionNo" is not null then 'Advance - ' || coalesce(public._advance_order_prod_status(p), 'New')
            else coalesce('Walk-in - ' || public._walkin_order_stage(s."OrderID"), o."Status", '-') end as current_status,
       coalesce(nullif(trim(s."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName", a."CustomerName") as customer
from public."DeliveryStops" s
left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
left join public."AdvanceOrderProduction" p on p."TransactionNo" = s."AdvanceTransactionNo"
where s."DeliveryDate" >= (now() at time zone 'Asia/Manila')::date
  and (
    s."AutomatedOrderNo" is not null
    or (s."AdvanceTransactionNo" is not null
        and p."ToShipAtUtc" is null and p."ShippedAtUtc" is null and p."DeliveredAtUtc" is null)
    or (s."OrderID" is not null
        and not public._order_status_past_to_ship(o."Status")
        and not (o."ReceivedAtShop" is true and o."PickedUpAtUtc" is not null))
    or (s."OrderID" is not null and public._walkin_order_stage(s."OrderID") in ('To Assign', 'Assigned'))
  )
order by s."DeliveryDate", order_id;
