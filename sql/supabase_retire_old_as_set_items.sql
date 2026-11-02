-- Make the old AS-xxx set items inactive, per "can we do the recommended fix.. since we are only increasing the
-- set package not the product". The price increase only raises SET-xxx packages, and staff product search
-- (staff_search_items_wildcard) only checks IsActive, so an active AS-xxx could still be picked at its old price.
--
-- Only retires an AS-xxx item when its SET-xxx replacement is really on sale: the package exists with a price, its
-- Items row is active, and it's the same set (same name, or the AS item resolves to that package). Anything else
-- stays active and is listed with the reason. Prices, HideFromSet, past orders and sales history are untouched.
-- Open orders are safe: set explosion finds the package by code / variation and doesn't check IsActive.
--
-- PortalEditedAtUtc is set like an Item Setup edit, so the POS pull (pos_list_items_master) carries the change.
-- To reverse one item, tick Active again in Item Setup.
--
-- Safe to re-run. Result: one row per SET-category item with no package of its own.

with eligible as (
  select i."Code"
    from public."Items" i
    join public."CompleteAquariumSetHeader" h on lower(trim(h."SetCode")) = 'set-' || lower(substr(trim(i."Code"), 4))
    join public."Items" s on s."Code" = trim(h."SetCode")
   where trim(i."Code") ilike 'AS-%'
     and upper(trim(coalesce(i."CategoryCode", ''))) = 'SET'
     and i."IsActive" is not false
     and coalesce(h."PackagePrice", 0) > 0
     and s."IsActive" is true
     and (lower(trim(coalesce(i."Name", ''))) = lower(trim(h."PackageName"))
          or public._resolve_set_package(i."VariationId", i."Code") = h."PackageName")
     and not exists (select 1 from public."CompleteAquariumSetHeader" own
                      where lower(trim(own."SetCode")) = lower(trim(i."Code")))
)
update public."Items" i
   set "IsActive" = false,
       "PortalEditedAtUtc" = now(),
       "PortalEditedBy" = 'AS-retire'
  from eligible e
 where i."Code" = e."Code";

select case
         when i."IsActive" is false then 'INACTIVE'
         when trim(i."Code") not ilike 'AS-%' then 'LEFT ACTIVE - not an AS item'
         when h."SetCode" is null then 'LEFT ACTIVE - no matching SET package'
         when coalesce(h."PackagePrice", 0) <= 0 then 'LEFT ACTIVE - SET package has no price'
         when s."IsActive" is not true then 'LEFT ACTIVE - SET item is not active'
         else 'LEFT ACTIVE - SET package looks like a different set'
       end as result,
       trim(i."Code") as code, i."Name" as name, coalesce(i."RetailPrice", i."Price") as old_item_price,
       trim(h."SetCode") as set_code, h."PackageName" as set_name, h."PackagePrice" as set_price
  from public."Items" i
  left join public."CompleteAquariumSetHeader" h on lower(trim(h."SetCode")) = 'set-' || lower(substr(trim(i."Code"), 4))
                                                and trim(i."Code") ilike 'AS-%'
  left join public."Items" s on s."Code" = trim(h."SetCode")
 where upper(trim(coalesce(i."CategoryCode", ''))) = 'SET'
   and not exists (select 1 from public."CompleteAquariumSetHeader" own
                    where lower(trim(own."SetCode")) = lower(trim(i."Code")))
 order by case when i."IsActive" is false then 2 else 1 end, trim(i."Code");
