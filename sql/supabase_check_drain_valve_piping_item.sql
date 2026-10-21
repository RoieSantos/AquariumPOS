-- One-off lookup for the "custom piping with drain valve" item, so it can be wired into the
-- Customize Aquarium sump options (today the builder only has one "Set of Piping" checkbox at a
-- fixed price: 540 for Overhead Sump, 2500 for Undersump). Lists every item that looks like a
-- piping/valve/drain product, plus everything tagged CUSTOM-PIPINGS. Safe to re-run, read-only.

select "Code", "Name", "Description", "Price", "RetailPrice", "CategoryCode", "IsActive"
from public."Items"
where "CategoryCode" = 'CUSTOM-PIPINGS'
   or "Name" ilike '%valve%' or "Description" ilike '%valve%'
   or "Name" ilike '%drain%' or "Description" ilike '%drain%'
   or "Name" ilike '%piping%' or "Description" ilike '%piping%'
order by "IsActive" desc, "CategoryCode", "Name";
