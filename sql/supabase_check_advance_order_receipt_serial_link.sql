-- Read-only check for supabase_advance_order_serials.sql. Advance-order serials are linked by
-- ItemSerialTracking."SoldOnlineOrderId" = 'ADV-' || TransactionNo, because ReceiptNos repeat across stores
-- (the first run of this check found shared receipts). This shows how much that matters for the OLDER POS
-- Pay In Full serials, which only carry the receipt: those are only counted for an order when its receipt
-- is used by ONE advance order and the serial sits at the order's warehouse. No "must be 0" rows any more.

select 'info' as kind, 'advance orders sharing a ReceiptNo (their older POS serials are not auto-linked)' as item,
       count(*)::text as detail
from public."AdvanceOrders" a
where nullif(trim(a."ReceiptNo"), '') is not null
  and (select count(*) from public."AdvanceOrders" x where x."ReceiptNo" = a."ReceiptNo") > 1
union all
select 'info', 'advance orders with no ReceiptNo (fine - the link uses TransactionNo)',
       count(*)::text
from public."AdvanceOrders" where nullif(trim("ReceiptNo"), '') is null
union all
select 'info', 'serials linked as ADV-<TransactionNo> (portal Ready to Ship / new POS build)',
       count(*)::text
from public."ItemSerialTracking" where "SoldOnlineOrderId" like 'ADV-%'
union all
select 'info', 'older POS serials with an advance ReceiptNo (receipt only)',
       count(*)::text
from public."ItemSerialTracking" s
where nullif(trim(s."SoldOnlineOrderId"), '') is null
  and exists (select 1 from public."AdvanceOrders" a where a."ReceiptNo" = s."SoldReceiptNo")
union all
select 'problem', 'TransactionNo values that look duplicated across stores (must be 0)',
       count(*)::text
from (select upper(trim("TransactionNo")) from public."AdvanceOrders" group by 1 having count(*) > 1) d;
