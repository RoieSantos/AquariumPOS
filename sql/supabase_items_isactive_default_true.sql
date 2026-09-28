-- "how about in future.. can we search items still" - follow-up to supabase_activate_octagon_items.sql.
--
-- ROOT CAUSE: the Pancake product sync (supabase_pancake_item_sku_match_fix.sql) inserts new Items
-- without an "IsActive" value, and the column had no default - so every item added from Pancake
-- landed with IsActive = NULL. public_search_items (GMA Create Order, product lookup, Alice),
-- staff_search_items and the Order Now page all require IsActive = true, so those items never
-- showed up in search even though the Items page lists them.
--
-- FIX: default the column to true so new items are searchable from the moment they sync, and turn
-- the existing NULLs (never set by anyone) on. Items explicitly set to false are left alone - that
-- is a deliberate "hide this item".

-- STEP 1 (preview): the items this will make searchable. Worth a glance for 0.00-priced items -
-- once active they also show on Order Now and in Alice's product search.
select "Code", "Name", "CategoryCode", coalesce("RetailPrice", "Price", 0) as price
from public."Items"
where "IsActive" is null
order by "CategoryCode", "Name";

-- STEP 2: new items default to active from now on.
alter table public."Items" alter column "IsActive" set default true;

-- STEP 3: turn on the existing never-set ones.
update public."Items"
set "IsActive" = true
where "IsActive" is null;
