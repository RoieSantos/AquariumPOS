-- One-off cleanup: wipes test data out of the Item Ledger for a fresh start, per direct request
-- ("do i need to run any sql?" -> "if i want to clear the entries. should I only delete the item
-- ledger entries for a fresh start?" -> "no i just want to wipe my testing data").
--
-- WHY A PLAIN DELETE DOESN'T WORK
-- "ItemLedgerEntries" is deliberately append-only (supabase_item_ledger_entries.sql) - triggers
-- block UPDATE/DELETE/TRUNCATE outright, so a mistake is normally corrected by posting a reversing
-- entry, never by editing history. The one documented escape hatch for a deliberate one-off wipe
-- like this is a table owner disabling those triggers in the SQL editor, clearing the table, then
-- re-enabling them immediately - that's what Step 1/2/3 below do, wrapped in one transaction so a
-- failure partway rolls everything back (including re-enabling the triggers) rather than leaving
-- the table unprotected.
--
-- WHAT ELSE NEEDS RESETTING (asked and confirmed: reset these too, not left mismatched)
-- Purchase Order / Transfer Order running totals are NOT derived from the ledger automatically -
-- they're their own stored columns that only move when something explicitly posts to them. Wiping
-- the ledger alone would leave PurchaseOrderLines.QtyReceived / Transfer_Line's Qty Shipped/Received
-- still claiming quantity that no longer has any ledger history behind it. Steps 4-5 reset those
-- back to zero/blank on every LIVE (not yet posted/archived) line.
--
-- WHAT THIS DOES NOT TOUCH (read before running)
--   * Purchase/Transfer Order HEADERS' own "Status" column (e.g. "Partially Received", "In-Transit",
--     "Received") - that's written by the portal UI itself when a receive/ship action runs, not
--     computed from the ledger or from QtyReceived/Qty Shipped/Received. After this script, any test
--     document whose lines just got zeroed will still SHOW its old status until you open it and
--     interact with it again (or fix the Status column by hand). If you have specific test PO/
--     Transfer document numbers you want fully deleted (header + lines) instead of just zeroed, tell
--     me the numbers and I'll add that - I can't safely guess which live documents are test data and
--     which are real from here.
--   * Posted_PurchaseOrders/Posted_PurchaseOrderLines and Posted_Transfer_Header/Posted_Transfer_Line
--     - already-archived historical documents, a different pair of tables entirely. Not touched.
--
-- CORRECTION FROM THE FIRST VERSION OF THIS FILE (caught by a real run erroring out)
-- Updating Transfer_Line's "Qty Shipped"/"Qty Received" is NOT a quiet reset - it fires
-- "TR_Transfer_Line_ItemLedger" (supabase_item_ledger_hooks.sql), which posts a NEW ledger entry for
-- the delta. Left as a plain UPDATE, Step 5 would try to post fresh entries into the ledger this
-- script just wiped - exactly backwards, and it can also fail outright on a bad variant/item link
-- (which is what actually happened: P0001, "Variant ... does not belong to item 'SERVICES'"). Step 5
-- now disables that trigger first, same escape-hatch pattern as Steps 1-3.
--
-- Also: Items."QuantityInStock" IS kept in step with the ledger (supabase_item_ledger_sales.sql's
-- "TR_ItemLedgerEntries_SyncItemQuantity"), but only on INSERT - a TRUNCATE fires no row triggers at
-- all, so every item's QuantityInStock would be left stale at its pre-wipe number otherwise. New
-- Step 7 recomputes it for every item via that file's own _ile_sync_all_item_quantities() (built for
-- exactly this kind of recompute).
--
-- Run this whole file at once in the Supabase SQL editor (it's one transaction).

begin;

-- ---------------------------------------------------------------------------------------------
-- Step 1. Temporarily lift the append-only guard.
-- ---------------------------------------------------------------------------------------------
alter table public."ItemLedgerEntries" disable trigger "TR_ItemLedgerEntries_NoUpdateDelete";
alter table public."ItemLedgerEntries" disable trigger "TR_ItemLedgerEntries_NoTruncate";

-- ---------------------------------------------------------------------------------------------
-- Step 2. Wipe the ledger. restart identity also resets EntryNo back to 1, and the separate
--         transaction-number sequence used by adjustments/receipts/reversals/postings.
-- ---------------------------------------------------------------------------------------------
truncate table public."ItemLedgerEntries" restart identity;
alter sequence public.ile_transaction_no_seq restart with 1;

-- ---------------------------------------------------------------------------------------------
-- Step 3. Put the append-only guard straight back.
-- ---------------------------------------------------------------------------------------------
alter table public."ItemLedgerEntries" enable trigger "TR_ItemLedgerEntries_NoUpdateDelete";
alter table public."ItemLedgerEntries" enable trigger "TR_ItemLedgerEntries_NoTruncate";

-- ---------------------------------------------------------------------------------------------
-- Step 4. Reset live Purchase Order lines' received quantity - nothing has actually been received
--         against a now-empty ledger.
-- ---------------------------------------------------------------------------------------------
update public."PurchaseOrderLines" set "QtyReceived" = 0 where "QtyReceived" <> 0;

-- ---------------------------------------------------------------------------------------------
-- Step 5. Same for live Transfer Order lines - shipped/received quantities, and the "increment
--         about to be entered" fields, back to blank. Trigger disabled first - see the
--         "CORRECTION" note above; without this the UPDATE tries to POST new ledger entries for
--         the delta instead of quietly resetting the columns.
-- ---------------------------------------------------------------------------------------------
alter table public."Transfer_Line" disable trigger "TR_Transfer_Line_ItemLedger";

update public."Transfer_Line"
   set "Qty Shipped" = 0, "Qty Received" = 0, "Qty To Ship" = null, "Qty To Receive" = null
 where coalesce("Qty Shipped", 0) <> 0 or coalesce("Qty Received", 0) <> 0
    or "Qty To Ship" is not null or "Qty To Receive" is not null;

alter table public."Transfer_Line" enable trigger "TR_Transfer_Line_ItemLedger";

-- ---------------------------------------------------------------------------------------------
-- Step 6. Clear the Physical Inventory Journal worksheet - not the ledger itself, but its
--         Qty. (Calculated) values are frozen numbers read from the ledger at Calculate time, now
--         stale. Ordinary table, no append-only guard, safe to just delete.
-- ---------------------------------------------------------------------------------------------
delete from public."PhysInventoryJournalLines";

-- ---------------------------------------------------------------------------------------------
-- Step 7. Recompute Items.QuantityInStock for every item - it's kept in step with the ledger by an
--         INSERT trigger (supabase_item_ledger_sales.sql), which a TRUNCATE never fires, so it
--         would otherwise be left showing stale pre-wipe numbers. With the ledger now empty, every
--         item's total is 0.
-- ---------------------------------------------------------------------------------------------
select public._ile_sync_all_item_quantities();

commit;

-- ---------------------------------------------------------------------------------------------
-- Verification - expect 0 rows / 0 counts everywhere.
-- ---------------------------------------------------------------------------------------------
select count(*) as remaining_ledger_entries from public."ItemLedgerEntries";
select count(*) as po_lines_still_showing_received from public."PurchaseOrderLines" where "QtyReceived" <> 0;
select count(*) as transfer_lines_still_showing_shipped_or_received
  from public."Transfer_Line" where coalesce("Qty Shipped", 0) <> 0 or coalesce("Qty Received", 0) <> 0;
select count(*) as remaining_phys_journal_lines from public."PhysInventoryJournalLines";
select count(*) as items_still_showing_nonzero_quantity from public."Items" where "QuantityInStock" <> 0;
