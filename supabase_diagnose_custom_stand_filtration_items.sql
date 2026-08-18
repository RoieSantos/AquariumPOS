-- Diagnostic + setup helper for the new standalone Customize > Stand and Customize > Filtration
-- flows (docs/js/orderNow.js's buildCustomStandCartLine/buildStandaloneFiltrationCartLine), which
-- submit AutomatedOrderLines with CategoryCode = 'CUSTOM-STAND' / 'CUSTOM-FILTRATION' and no
-- ItemCode - same pattern the existing Custom Aquarium line already uses (CategoryCode =
-- 'CUSTOM-AQUARIUM', see supabase_diagnose_custom_aquarium_item.sql).
--
-- _push_automated_order_to_pancake (supabase_automated_orders_tables.sql) matches a line to a
-- Pancake product by:
--   i."Code" = coalesce(l."ItemCode", l."CategoryCode")
--   or (l."ItemCode" is null and i."Name" = l."CategoryCode")
-- For these two new line types (no ItemCode), that means it needs an Items row whose "Name" (or
-- "Code") is exactly 'CUSTOM-STAND' / 'CUSTOM-FILTRATION', with a real VariationId or ProductId
-- from your Pancake catalog. Without that row, every Stand/Filtration order will push to Pancake
-- with "None of this order's lines matched a known Pancake product" and land as PancakeSyncStatus
-- = 'Failed' - the order itself is still recorded normally either way (see
-- _push_automated_order_to_pancake's never-raises contract), this only affects the Pancake sync.

-- 1. Do matching Items rows already exist?
select "Code", "Name", "VariationId", "ProductId", "CategoryCode", "IsActive"
from public."Items"
where "Code" in ('CUSTOM-STAND', 'CUSTOM-FILTRATION') or "Name" in ('CUSTOM-STAND', 'CUSTOM-FILTRATION');

-- 2. If query 1 came back empty (or only partial) for either, is there something close already
--    under a different name? (e.g. an existing "Custom Sump"/"Custom Filtration Setup" item)
select "Code", "Name", "VariationId", "ProductId", "CategoryCode", "IsActive"
from public."Items"
where "Code" ilike '%custom%stand%' or "Name" ilike '%custom%stand%'
   or "Code" ilike '%custom%filtration%' or "Name" ilike '%custom%filtration%'
   or "Code" ilike '%custom%sump%' or "Name" ilike '%custom%sump%';

-- 3. Reference: the existing Custom Aquarium item this same push logic already relies on, so you
--    can see exactly what shape a working row needs (Code CI-005, Name CUSTOM-AQUARIUM).
select "Code", "Name", "VariationId", "ProductId", "CategoryCode", "IsActive"
from public."Items"
where "Code" = 'CI-005' or "Name" = 'CUSTOM-AQUARIUM';

-- 4. SETUP - only run this once you have real VariationId/ProductId values for these two products
--    from your Pancake catalog (Pancake dashboard > Products, or wherever CI-005's values came
--    from originally). Do NOT invent/guess these values - a wrong id silently pushes the order
--    against the WRONG Pancake product, which is worse and harder to notice than a Failed push.
--    Uncomment and fill in below, then run:
--
-- insert into public."Items" ("Code", "Name", "CategoryCode", "VariationId", "ProductId", "IsActive")
-- values
--   ('CUSTOM-STAND-ITEMCODE', 'CUSTOM-STAND', 'CUSTOM-STAND', '<real VariationId or null>', '<real ProductId or null>', true),
--   ('CUSTOM-FILTRATION-ITEMCODE', 'CUSTOM-FILTRATION', 'CUSTOM-FILTRATION', '<real VariationId or null>', '<real ProductId or null>', true)
-- on conflict ("Code") do update
--   set "Name" = excluded."Name",
--       "VariationId" = excluded."VariationId",
--       "ProductId" = excluded."ProductId",
--       "IsActive" = excluded."IsActive";
