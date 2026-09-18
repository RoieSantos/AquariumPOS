-- Diagnostic + setup helper for the new "+ Custom Stickers / Accessories" quote button in GMA
-- Conversations' Create Order tab (docs/gma-conversations.html/js/gmaConversations.js), which adds
-- an order line with CategoryCode = 'CUSTOM-STICKER' and no ItemCode - the SAME convention
-- docs/js/orderNow.js's Customize > Accessories/Stickers flow already uses
-- (buildStandaloneStickerCartLine), and the same pattern as the existing Custom Aquarium/Stand lines
-- (see supabase_diagnose_custom_aquarium_item.sql / supabase_diagnose_custom_stand_filtration_items.sql).
--
-- _push_automated_order_to_pancake (supabase_automated_orders_tables.sql) matches a line to a
-- Pancake product by:
--   i."Code" = coalesce(l."ItemCode", l."CategoryCode")
--   or (l."ItemCode" is null and i."Name" = l."CategoryCode")
-- For this line type (no ItemCode), that means it needs an Items row whose "Name" (or "Code") is
-- exactly 'CUSTOM-STICKER', with a real VariationId or ProductId from your Pancake catalog. Without
-- that row, any order containing a sticker/accessory line will push to Pancake with "None of this
-- order's lines matched a known Pancake product" and land as PancakeSyncStatus = 'Failed' - the
-- order itself is still recorded normally either way (see _push_automated_order_to_pancake's
-- never-raises contract), this only affects the Pancake sync.

-- 1. Does a matching Items row already exist?
select "Code", "Name", "VariationId", "ProductId", "CategoryCode", "IsActive"
from public."Items"
where "Code" = 'CUSTOM-STICKER' or "Name" = 'CUSTOM-STICKER';

-- 2. If query 1 came back empty, is there something close already under a different name? (e.g. an
--    existing "Custom Accessory"/"Custom Sticker Service" item)
select "Code", "Name", "VariationId", "ProductId", "CategoryCode", "IsActive"
from public."Items"
where "Code" ilike '%custom%sticker%' or "Name" ilike '%custom%sticker%'
   or "Code" ilike '%custom%accessor%' or "Name" ilike '%custom%accessor%';

-- 3. Reference: the existing Custom Aquarium item this same push logic already relies on, so you
--    can see exactly what shape a working row needs (Code CI-005, Name CUSTOM-AQUARIUM).
select "Code", "Name", "VariationId", "ProductId", "CategoryCode", "IsActive"
from public."Items"
where "Code" = 'CI-005' or "Name" = 'CUSTOM-AQUARIUM';

-- 4. SETUP - only run this once you have a real VariationId/ProductId for this product from your
--    Pancake catalog (Pancake dashboard > Products, or wherever CI-005's values came from
--    originally). Do NOT invent/guess these values - a wrong id silently pushes the order against
--    the WRONG Pancake product, which is worse and harder to notice than a Failed push.
--    Uncomment and fill in below, then run:
--
-- insert into public."Items" ("Code", "Name", "CategoryCode", "VariationId", "ProductId", "IsActive")
-- values
--   ('CUSTOM-STICKER-ITEMCODE', 'CUSTOM-STICKER', 'CUSTOM-STICKER', '<real VariationId or null>', '<real ProductId or null>', true)
-- on conflict ("Code") do update
--   set "Name" = excluded."Name",
--       "VariationId" = excluded."VariationId",
--       "ProductId" = excluded."ProductId",
--       "IsActive" = excluded."IsActive";
