-- Read-only check: walk-in (WI-) orders that are really an advance order's Pay In Full - per "it saying on
-- the dashboard its gcash income for today's sales but in reality its a full payment for a advance order"
-- (WI-00326 / RS-0000011680).
--
-- Cause: advance order Pay In Full (POS) writes a SALES TransactionHeader under the advance order's own
-- receipt. Since advance orders went portal-only nothing marked it sent, so the POS resend
-- (SendFailedTransactionToCloud) turned it into a "POS WALKIN ORDERS" walk-in with a POS-FALLBACK line,
-- and its payment counted as walk-in sales. Fixed in the POS (OnlinefunctionsEvents.IsAdvanceOrderReceipt).
--
-- Each row here is a stray walk-in: delete it with the order card's "Delete Order" button (Super User),
-- or tick them on the Walk-in list and "Delete Selected". The advance order itself is untouched.
-- Safe to re-run. Ends with ONE result.

select o."OrderID"                         as walkin_order,
       o."Date"                            as walkin_date,
       o."PosReceiptNo"                    as receipt_no,
       a."TransactionNo"                   as advance_transaction_no,
       a."CustomerName"                    as advance_customer,
       o."PosWarehouseId"                  as walkin_store,
       a."Warehouse"                       as advance_store,   -- each store has its own RS- numbers: check these agree
       o."MoneyToCollect"                  as walkin_total,
       o."AmountPaid"                      as walkin_paid,
       (select string_agg(p."MethodCode" || ': ' || p."Amount", ', ')
          from public."OnlineOrderPayments" p where p."OrderID" = o."OrderID") as walkin_payments,
       (select string_agg(coalesce(l."ItemCode", l."product_display_id"), ', ')
          from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") as walkin_lines
  from public."OnlineOrders" o
  join public."AdvanceOrders" a
    on a."ReceiptNo" = o."PosReceiptNo"
 where o."OrderID" like 'WI-%'
 order by o."Date" desc, o."OrderID";
