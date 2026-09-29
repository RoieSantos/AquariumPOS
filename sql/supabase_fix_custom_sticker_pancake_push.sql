-- Fixes Automated Order AO-00023 (GMA, Custom Aquarium + Custom Accessory/Sticker) failing its Pancake
-- push with "1 of 2 order lines matched a known Pancake product - refusing a partial push."
--
-- CAUSE: a Custom Accessory/Sticker line is saved with CategoryCode = 'CUSTOM-STICKER' and no ItemCode.
-- _push_automated_order_to_pancake (supabase_gma_conversation_order_line_variant_selection.sql) can
-- only send a line when an Items row with Code/Name = 'CUSTOM-STICKER' has a real Pancake
-- VariationId/ProductId - the way CUSTOM-AQUARIUM (CI-005) does. That row was never set up (flagged in
-- supabase_diagnose_custom_sticker_item.sql), so the Custom Aquarium line matched and the sticker
-- line didn't, and the push refuses to send a half order.
--
-- Run the steps one at a time in the Supabase SQL editor.

-- 1. Confirm: expect NO row here (or a row with VariationId and ProductId both null).
select "Code", "Name", "VariationId", "ProductId", "CategoryCode", "IsActive"
from public."Items"
where "Code" = 'CUSTOM-STICKER' or "Name" = 'CUSTOM-STICKER'
   or "Name" ilike '%custom%sticker%' or "Name" ilike '%custom%accessor%';

-- 2. Find the product in Pancake. Needs debug_find_pancake_product (supabase_debug_pancake_product_search.sql).
--    Try the name you gave it in Pancake - e.g. 'CUSTOM-STICKER', 'STICKER', 'ACCESSOR'.
--    If none is found, first create a "CUSTOM-STICKER" product in Pancake (same way CUSTOM-AQUARIUM
--    exists there), then run this again.
select found_on_page, pages_searched,
       raw_product ->> 'id' as product_id,
       raw_product ->> 'name' as name,
       raw_product -> 'variations' -> 0 ->> 'id' as variation_id,
       raw_product -> 'variations' -> 0 ->> 'display_id' as variation_display_id
from public.debug_find_pancake_product('STICKER');

-- 3. Link it: paste the product_id / variation_id from step 2 (do NOT guess - a wrong id pushes orders
--    against the wrong Pancake product). Uncomment, fill in, run.
--
-- insert into public."Items" ("Code", "Name", "CategoryCode", "VariationId", "ProductId", "IsActive")
-- values ('CUSTOM-STICKER', 'CUSTOM-STICKER', 'CUSTOM-STICKER', '<variation_id>', '<product_id>', true)
-- on conflict ("Code") do update
--   set "Name" = excluded."Name",
--       "VariationId" = excluded."VariationId",
--       "ProductId" = excluded."ProductId",
--       "IsActive" = excluded."IsActive";

-- 4. Retry the push (or click "Retry Push to Pancake" on the order), then check it says Synced.
select public._push_automated_order_to_pancake('AO-00023');

select "OrderNo", "PancakeSyncStatus", "PancakeSyncError", "PancakeReceiptNo"
from public."AutomatedOrders"
where "OrderNo" = 'AO-00023';
