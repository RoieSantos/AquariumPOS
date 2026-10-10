-- Indexes for "which serials are linked to this order" - per "will this load up slow and affect
-- performance?" before adding the Serials FactBox to the Online Orders list.
--
-- staff_get_online_order_serial_labels (WHERE "SoldOnlineOrderId" = order id) and _advance_order_serials
-- ('ADV-' || TransactionNo, or the older POS receipt-only link on "SoldReceiptNo" + a count of
-- AdvanceOrders by "ReceiptNo") had no index to use, so every card open / list selection read the whole
-- ItemSerialTracking table. With these, each lookup only touches the order's own rows (the advance OR
-- becomes a BitmapOr of the two serial indexes).
--
-- Used by the order cards' Show Serials / Serials FactBox and the list's Serials FactBox
-- (docs/js/onlineOrders.js). Safe to re-run. Ends with one result: the three indexes.

create index if not exists "IX_ItemSerialTracking_SoldOnlineOrderId"
  on public."ItemSerialTracking" ("SoldOnlineOrderId");

create index if not exists "IX_ItemSerialTracking_SoldReceiptNo"
  on public."ItemSerialTracking" ("SoldReceiptNo");

create index if not exists "IX_AdvanceOrders_ReceiptNo"
  on public."AdvanceOrders" ("ReceiptNo");

analyze public."ItemSerialTracking";
analyze public."AdvanceOrders";

select tablename, indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and indexname in ('IX_ItemSerialTracking_SoldOnlineOrderId', 'IX_ItemSerialTracking_SoldReceiptNo', 'IX_AdvanceOrders_ReceiptNo')
order by tablename, indexname;
