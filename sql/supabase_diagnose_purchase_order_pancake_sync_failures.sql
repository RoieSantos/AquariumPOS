-- One-off diagnostic: lists recent Failed/Rejected Purchase Order -> Pancake receiving pushes
-- (the "Pancake Sync" panel on the Receive Purchase Order modal, see
-- supabase_purchase_order_pancake_sync.sql), together with the exact "note" value Pancake would
-- have stored on that purchase (PONo || '-' || PurchaseEventNo) - staff_receive_purchase_order_
-- lines deliberately does NOT auto-retry a failed push (no confirmed GET /purchases-by-note
-- lookup exists in this codebase to safely verify-before-retry, unlike the Transfer Orders sync -
-- see that function's header comment), so a "Failed" row here does not by itself mean nothing
-- reached Pancake: a connection-level error (e.g. "OpenSSL SSL_read: SSL_ERROR_SYSCALL") can
-- happen AFTER Pancake already received and processed the request, while only the response read
-- failed locally.
--
-- How to use: run this in the Supabase SQL editor, then for each row search Pancake's own
-- Purchases (Inventory) list for that row's warehouse for a purchase with the given "search_note"
-- value. If found there -> it already went through, do NOT receive that quantity again (would
-- double the stock-in). If NOT found there -> the push genuinely never landed, safe to hit
-- Receive again for that same quantity.

select
  p."PurchaseEventNo",
  p."PONo",
  p."WarehouseId",
  p."WarehouseName",
  p."PONo" || '-' || p."PurchaseEventNo"::text as search_note,
  p."Sync Status",
  p."Sync Error",
  p."Items Json",
  p."ReceivedBy",
  p."ReceivedAtUtc"
from public."PurchaseOrder_Pancake_Purchases" p
where p."Sync Status" in ('Failed', 'Rejected')
order by p."ReceivedAtUtc" desc
limit 50;
