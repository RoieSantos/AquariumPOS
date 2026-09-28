-- One-off: "im searching octagon but I cannot find it" in GMA Conversations > Create Order.
-- The product search (public_search_items) only returns Items with "IsActive" = true, while the
-- Items page lists every item regardless - so an inactive item shows on the Items page but never
-- in the search. Run STEP 1 first to confirm, then STEP 2.
--
-- SCOPE: "IsActive" also gates the Order Now page, the staff item pickers (staff_search_items) and
-- Alice's product search - activating these makes them findable there too.

-- STEP 1: check. Expect is_active = false or null for both rows.
select "Code", "Name", "CategoryCode", "IsActive" as is_active, "Price", "RetailPrice"
from public."Items"
where "Name" ilike '%octagon%' or "Code" in ('AQ-041', 'AST-017');

-- STEP 2: activate them.
update public."Items"
set "IsActive" = true
where "Code" in ('AQ-041', 'AST-017')
  and "IsActive" is distinct from true;

-- Optional: list every other inactive item in the same category, in case more are hidden.
select "Code", "Name", "IsActive"
from public."Items"
where trim(coalesce("CategoryCode", '')) = 'CUSTOMIZED ITEM'
  and "IsActive" is distinct from true
order by "Name";
