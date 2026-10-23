-- Read-only check: advance orders whose downpayment is under 50% of the order total - per "there are
-- transaction coming in with no 50% downpayment.. i think this is on the local POS".
--
-- The POS (MainForm.SaveAdvanceOrder) saves an advance order with whatever was tendered - there is no
-- 50% minimum there; only the Xendit pay link (_xendit_down_payment_due) uses 50%.
--
-- "Downpayment" on AdvanceOrders is cumulative (later balance payments add to it), so a row listed here
-- is still under 50% today; an order that started under 50% but has since been topped up won't show.
-- Last 90 days, newest first. Safe to re-run.

select a."TransactionNo"                                   as transaction_no,
       a."ReceiptNo"                                       as receipt_no,
       a."Date"                                            as order_date,
       a."Warehouse"                                       as warehouse,
       a."UserID"                                          as cashier,
       a."CustomerName"                                    as customer,
       a."NetAmount"                                       as total,
       a."Downpayment"                                     as paid_so_far,
       round(a."NetAmount" * 0.5, 2)                       as fifty_pct,
       round(100 * coalesce(a."Downpayment", 0) / nullif(a."NetAmount", 0), 1) as paid_pct,
       a."Balance"                                         as balance,
       a."Order_Description"                               as description
  from public."AdvanceOrders" a
 where coalesce(a."NetAmount", 0) > 0
   and coalesce(a."Downpayment", 0) < a."NetAmount" * 0.5
   and coalesce(a."FullyPaid", false) = false
   and a."Date" >= (now() at time zone 'Asia/Manila')::date - 90
 order by a."Date" desc, a."TransactionNo" desc;
