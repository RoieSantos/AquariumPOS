-- One-off check for "2 of 3 order lines matched a known Pancake product - refusing a partial
-- push" on Customize-flow orders (Custom Aquarium/Stand/Filtration lines) - see
-- _push_automated_order_to_pancake in supabase_automated_orders_tables.sql, which matches those
-- lines by Items."Name" = 'CUSTOM-AQUARIUM' / 'CUSTOM-STAND' / 'CUSTOM-FILTRATION' (they carry no
-- real ItemCode, per js/orderNow.js's buildCustomAquariumCartLine/buildCustomStandCartLine/
-- buildStandaloneFiltrationCartLine - itemCode is always null for these) AND requires that
-- matched Items row to have a VariationId or ProductId (i.e. actually linked to a real Pancake
-- product, not just sitting in the local catalog). This shows exactly which of the three
-- placeholder items is missing or unlinked. Safe to re-run, read-only.

select "Code", "Name", "CategoryCode", "VariationId", "ProductId", "IsActive", "SyncedAtUtc"
from public."Items"
where "Name" in ('CUSTOM-AQUARIUM', 'CUSTOM-STAND', 'CUSTOM-FILTRATION');
