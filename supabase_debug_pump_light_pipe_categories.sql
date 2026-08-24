-- One-off check for adding Pumps/Lights/Pipes to Order Now's Standard flow (js/orderNow.js's
-- STANDARD_FLOW_CATEGORY_CODES). PUMP and LIGHTS were added assuming the codes in
-- supabase_categories_backfill.sql are still accurate - that file is only a manual, one-time
-- snapshot (Categories syncs by hand, not automatically - see supabase_warehouses_items_tables.sql),
-- so this confirms it against what's live right now, and looks for a Pipes-equivalent category
-- (only CUSTOM-PIPINGS - clearly meant for the Customize builder, not a standalone catalog
-- category - showed up in that snapshot). Safe to re-run, read-only.

-- 1) Every category whose code/description mentions pump, light, or pipe.
select "Code", "Description", "IsProductionCategory"
from public."Categories"
where "Code" ilike '%pump%' or "Description" ilike '%pump%'
   or "Code" ilike '%light%' or "Description" ilike '%light%'
   or "Code" ilike '%pipe%' or "Description" ilike '%pipe%'
order by "Code";

-- 2) Does PUMP/LIGHTS actually have active items tagged with that exact CategoryCode? A category
-- with zero matches here would show as an empty "No items available" tile on Order Now even
-- though the button appears.
select "CategoryCode", count(*) as active_item_count
from public."Items"
where "IsActive" is true
  and "CategoryCode" in ('PUMP', 'LIGHTS', 'Aquarium Lights', 'CUSTOM-PIPINGS')
group by "CategoryCode"
order by "CategoryCode";
