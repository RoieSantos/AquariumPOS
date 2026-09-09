-- One-off manual fix for Online Order 83966 (RS-0000010463, customer ABEL): the CUSTOM-AQUARIUM
-- and CUSTOM-SUMP line items never made it into public."OnlineOrderLines" because Pancake's own
-- sync (cron_sync_online_orders_from_pancake / admin_backfill_online_order_lines) silently skips
-- any line missing a product_display_id, and these two custom-build lines had none.
--
-- We tried fixing it at the source first (PUT/PATCH to Pancake's own order endpoint with the two
-- items added), but the order's status_name is already "shipped" - Pancake accepted the request
-- (200 OK, header fields like `note` updated) but silently ignored the items array change, so the
-- order-of-record on Pancake's side will permanently show only the SERVICES line. This inserts the
-- two missing lines directly into Supabase instead, which is what actually feeds local reporting
-- (Top Selling Items, the Online Orders portal, etc.).
--
-- VariationId values below are Pancake's real catalog variation_id for CUSTOM-AQUARIUM/CUSTOM-SUMP
-- (confirmed via supabase_diagnose_custom_aquarium_item.sql / supabase_debug_custom_sump_item.sql).
-- LineID is synthetic ("MANUAL-...") since these lines have no real Pancake line id - safe to
-- re-run, upserts on the (OrderID, LineID) primary key.
--
-- NOTE: because Pancake itself never accepted these lines, a future re-sync of this order will
-- NOT create duplicates alongside these manual rows (nothing on Pancake's side to duplicate from).

insert into public."OnlineOrderLines" (
  "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "Discount", "GrossAmount", "NetAmount", "Note", "Description", "SyncedAtUtc"
) values
(
  '83966', 'MANUAL-CUSTOM-AQUARIUM', 'CUSTOM-AQUARIUM', 'CUSTOM-AQUARIUM', 'a67cd9a8-faec-4f77-a674-7707fb81c29d',
  1, null, 2020.00, null, 2020.00, null, null,
  'Aquarium Build | Tank L: 43.0" x W: 15.5" x H: 15.5" (6mm) (44.7 gal) | Glass 6mm | Black sealant | Aquarium only',
  now()
),
(
  '83966', 'MANUAL-CUSTOM-SUMP', 'CUSTOM-SUMP', 'CUSTOM-SUMP', '1a003166-6178-4f2e-b710-21baadd79323',
  1, null, 736.00, null, 736.00, null, null,
  'Aquarium Build | Tank L: 24.5" x W: 5.0" x H: 6.0" (6mm) (3.2 gal) | Glass 6mm | Black sealant | Overheadsump',
  now()
)
on conflict ("OrderID", "LineID") do update set
  "ItemCode" = excluded."ItemCode",
  "product_display_id" = excluded."product_display_id",
  "VariationId" = excluded."VariationId",
  "Quantity" = excluded."Quantity",
  "Price" = excluded."Price",
  "GrossAmount" = excluded."GrossAmount",
  "Description" = excluded."Description",
  "SyncedAtUtc" = now();

-- Verify: should now show all 3 lines for this order (SERVICES from the real Pancake sync, plus
-- the two manual ones below).
select "OrderID", "LineID", "ItemCode", "product_display_id", "Quantity", "Price", "GrossAmount", "Description", "SyncedAtUtc"
from public."OnlineOrderLines"
where "OrderID" = '83966'
order by "LineID";
