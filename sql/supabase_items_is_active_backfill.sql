-- Items showing ACTIVE on the Items page but missing from the GMA Conversations product search
-- (Product List panel + Create Order tab) - e.g. PI-030 FEMALE-GRAY 3/4 / PI-029 MALE-GRAY 3/4.
--
-- Cause: items that came in through the old Pancake sync were inserted without "IsActive", so it is
-- NULL. The Items page (itemSetup.js: is_active === false) and the store POS pull
-- (pos_list_items_master: coalesce(IsActive, true)) treat NULL as active, but the sales pickers -
-- staff_search_items_wildcard and public_list_order_items - require "IsActive" is true, so a NULL
-- item silently never shows up there.
--
-- Fix: set every NULL "IsActive" to true (what the Items page and POS already show for them) and give
-- the column a default of true so a future insert that leaves it out can't hit this again.
--
-- Safe to re-run. Ends with ONE result: how many are still blank (expect 0), then what searching
-- "gray 3/4" now finds.

update public."Items" set "IsActive" = true where "IsActive" is null;

alter table public."Items" alter column "IsActive" set default true;

select 'still blank (expect 0)' as section, count(*)::text as code, null::text as name, null::text as category_code
  from public."Items" where "IsActive" is null
union all
select 'search "gray 3/4"', code, name, category_code
  from public.staff_search_items_wildcard('gray 3/4');
