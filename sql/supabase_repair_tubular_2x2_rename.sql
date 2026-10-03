-- REPAIR: PI items wrongly renamed to "Tubular 2x2" by the old SKU-collision bug in the Pancake
-- Items sync - re-pulls every item's Name (and Price/Category/SKU/ProductId/Images) straight from
-- its own Pancake product. Run AFTER supabase_pancake_item_sku_match_fix.sql - with the old
-- SKU-matching functions still live, step 2 would just re-corrupt them.
--
-- Step 1: the bad syncs also copied the Tubular product's "ProductId" onto these rows, and the
-- fixed sync matches ProductId FIRST - so clear it, letting each row fall back to its exact Code
-- match (PI-041 -> Pancake PI-041, etc.). Harmless for the row that genuinely is Tubular 2x2.
-- Step 2: run the Items sync now instead of waiting for the 5-minute cron.
-- Cost/Vendor/Wholesale are portal-owned and never touched.
--
-- Safe to re-run. Ends with one result: the PI items after the re-sync.

update public."Items"
set "ProductId" = null
where "Name" ~* 'tubular\s*2\s*[x×]\s*2'
  and "CategoryCode" = 'PRODUCTION ITEM';

select * from public.cron_sync_items_from_pancake();

select "Code", "Name", "SKU", "ProductId", "CategoryCode", "SyncedAtUtc"
from public."Items"
where "Code" like 'PI-%'
order by "Code";
