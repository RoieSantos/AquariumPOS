-- One-off: remove the P1.00 "GCASH" test collection on AO-00192 (2026-11-10, driver "test driver") - it was recorded
-- by hand with Paid via GCash while no money came in, and went on the order as a payment. Removes:
--   - the DeliveryCollections row (manual, not a Xendit QR one),
--   - the AutomatedOrderPayments row it made ("Delivery - collected by ..."),
-- then recomputes AO-00192's Amount Paid / Balance from its remaining payments.
-- Only touches a manual P1.00 non-cash collection on AO-00192 made today. Safe to re-run (does nothing the 2nd time).
-- Ends with ONE result: what was removed and the order's balance now.

with target as (
  select dc."CollectionID", dc."CollectedBy", dc."MethodName"
  from public."DeliveryCollections" dc
  where dc."OrderRef" = 'AO-00192' and dc."Amount" = 1.00 and dc."MethodCode" <> 'CASH'
    and dc."XenditPaymentID" is null
    and (dc."CollectedAtUtc" at time zone 'Asia/Manila')::date = date '2026-11-10'
),
removed_payment as (
  delete from public."AutomatedOrderPayments" p
  where p."ctid" in (
    select p2."ctid" from public."AutomatedOrderPayments" p2, target t
    where p2."OrderNo" = 'AO-00192' and p2."Amount" = 1.00
      and p2."Reference" like 'Delivery - collected by ' || t."CollectedBy" || '%'
    limit 1)
  returning p."Amount"
),
removed_collection as (
  delete from public."DeliveryCollections" dc
  using target t where dc."CollectionID" = t."CollectionID"
  returning dc."CollectionID"
)
select 'removed' as section,
       (select count(*) from removed_collection)::text || ' collection, ' || (select count(*) from removed_payment)::text || ' order payment' as value;

-- Recompute the order from what's left (no-op if nothing changed).
update public."OnlineOrders" o
   set "AmountPaid" = coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = 'AO-00192'), 0),
       "Balance" = coalesce(o."MoneyToCollect", 0) - coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = 'AO-00192'), 0)
 where o."OrderID" = 'AO-00192';

-- Result: AO-00192 now.
select 'AO-00192' as section,
       'Paid ' || to_char(o."AmountPaid", 'FM999,999,990.00') || ' / Balance ' || to_char(o."Balance", 'FM999,999,990.00')
       || ' / collections left today: ' || (select count(*) from public."DeliveryCollections" dc
                                             where dc."OrderRef" = 'AO-00192'
                                               and (dc."CollectedAtUtc" at time zone 'Asia/Manila')::date = date '2026-11-10')::text as value
  from public."OnlineOrders" o where o."OrderID" = 'AO-00192';
