-- FIX: the "50Gallons Aquarium Overhead Complete Setup SET" package line points at ItemNo FROK-WHITE-3FT,
-- which is not an item code (the real item is L-001 FROK-SUBMERSIBLE-LIGHT (3FT, WHITE)). Re-point it so
-- Set Assembly (e.g. AO-000252) links the light and deducts its stock.
-- Fixes every package that still uses the old code. Safe to re-run (second run updates nothing).
update public."CompleteAquariumSetLine"
set "ItemNo" = 'L-001',
    "ItemName" = 'FROK-SUBMERSIBLE-LIGHT (3FT, WHITE)'
where trim("ItemNo") = 'FROK-WHITE-3FT'
returning "PackageName", "ItemNo", "ItemName", "Quantity";
