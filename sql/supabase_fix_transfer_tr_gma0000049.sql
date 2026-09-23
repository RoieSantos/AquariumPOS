-- One-off fix for Transfer Order TR-GMA0000049, per direct request after the Item Ledger wipe
-- reverted its lines back to "To Ship" (supabase_item_ledger_wipe_test_data.sql's Step 5 zeroed
-- every live Transfer_Line's Qty Shipped/Received - see that file's header for why): "can you make
-- all received except for AQ-030 Black Sealant it has pending 5 to-ship".
--
-- TARGET STATE (from the screenshot's Qty To Transfer column):
--   AQ-008 BlackSealant   (7  total) -> fully received:  Shipped 7,  Received 7
--   AQ-008 ClearSealant   (3  total) -> fully received:  Shipped 3,  Received 3
--   AQ-030 ClearSealant   (10 total) -> fully received:  Shipped 10, Received 10
--   AQ-030 BlackSealant   (10 total) -> PARTIAL:          Shipped 5,  Received 5  (5 still pending)
--   AQ-036 BlackSealant   (7  total) -> fully received:  Shipped 7,  Received 7
--   AQ-036 ClearSealant   (3  total) -> fully received:  Shipped 3,  Received 3
--
-- WHY THE TRIGGER IS DISABLED FIRST (same escape-hatch pattern as the wipe script)
-- A plain UPDATE of "Qty Shipped"/"Qty Received" fires "TR_Transfer_Line_ItemLedger"
-- (supabase_item_ledger_hooks.sql), which tries to POST the delta to the Item Ledger. Since the
-- ledger is currently empty (wiped), the shipment leg's negative-stock check would see Amaya
-- warehouse sitting at 0 for every one of these items and refuse the whole update ("Not enough
-- stock: ... has 0 on hand at Amaya"). This fix is about restoring the DOCUMENT's own state, not
-- about recreating ledger history, so the trigger is skipped entirely here.
--
-- KNOWN LIMITATION - READ BEFORE RUNNING: this does NOT create any matching Item Ledger entries for
-- this real stock movement (Amaya -> GMA), because the ledger has no record that Amaya ever held
-- this stock in the first place (wiped). After this runs, TR-GMA0000049 will correctly show as
-- received again on screen, but the portal's ledger/Stock On Hand numbers will NOT reflect this
-- transfer having happened. If you want that backfilled too, say so and we can look at posting
-- matching entries by hand (they'd carry today's date, not the real 9/16/2026 transfer date, since
-- that's what _ile_post always uses for a fresh entry).
--
-- Run this whole file at once in the Supabase SQL editor (it's one transaction).

begin;

alter table public."Transfer_Line" disable trigger "TR_Transfer_Line_ItemLedger";

update public."Transfer_Line" tl
   set "Qty Shipped" = v.target_qty,
       "Qty Received" = v.target_qty,
       "Qty To Ship" = null,
       "Qty To Receive" = null
  from public."Variants" var,
       (values
         ('AQ-008', 'AQ-008-BlackSealant', 7::numeric),
         ('AQ-008', 'AQ-008-ClearSealant', 3::numeric),
         ('AQ-030', 'AQ-030-ClearSealant', 10::numeric),
         ('AQ-030', 'AQ-030-BlackSealant', 5::numeric),
         ('AQ-036', 'AQ-036-BlackSealant', 7::numeric),
         ('AQ-036', 'AQ-036-ClearSealant', 3::numeric)
       ) as v(item_no, sku, target_qty)
 where tl."Document No." = 'TR-GMA0000049'
   and tl."Item No." = v.item_no
   and var."SKU" = v.sku
   and tl."Variant ID" = var."VariationId";

alter table public."Transfer_Line" enable trigger "TR_Transfer_Line_ItemLedger";

commit;

-- ---------------------------------------------------------------------------------------------
-- Verification - expect 6 rows, one per line above, with the target Shipped/Received quantities.
-- ---------------------------------------------------------------------------------------------
select tl."Item No.", var."SKU", tl."Qty Shipped", tl."Qty Received", tl."Qty To Ship", tl."Qty To Receive"
from public."Transfer_Line" tl
left join public."Variants" var on var."VariationId" = tl."Variant ID"
where tl."Document No." = 'TR-GMA0000049'
order by tl."Item No.", var."SKU";
