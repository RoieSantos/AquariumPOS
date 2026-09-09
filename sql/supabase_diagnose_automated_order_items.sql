-- One-off diagnostic for "no items shown after picking a category" on the Order Now wizard
-- (docs/order-now.html). public.public_list_order_items() only returns Items rows where
-- "IsActive" = true AND trim("CategoryCode") = trim(Categories."Code") - this checks whether any
-- rows actually satisfy that for each category, and flags a likely CategoryCode mismatch
-- (e.g. Items."CategoryCode" = 'Aquarium' vs Categories."Code" = 'AQUARIUM') if the raw item
-- count is non-zero but the matched count is zero.

-- 1) Every category, with how many active items match it via the exact join the wizard uses.
select
  c."Code" as category_code,
  c."Description" as category_description,
  count(i."Code") as matching_active_items
from public."Categories" c
left join public."Items" i
  on i."IsActive" is true
  and trim(coalesce(i."CategoryCode", '')) = trim(c."Code")
group by c."Code", c."Description"
order by matching_active_items desc, c."Code";

-- 2) Every distinct CategoryCode actually present on Items (active or not), so you can compare
-- spelling/casing against Categories."Code" above.
select "CategoryCode", count(*) as item_count, count(*) filter (where "IsActive" is true) as active_item_count
from public."Items"
group by "CategoryCode"
order by item_count desc;
