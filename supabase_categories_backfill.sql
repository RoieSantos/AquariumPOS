-- One-time (re-runnable) backfill of public."Categories" from the local dbo.Category table's
-- current IsProductionCategory/Description values (snapshot taken via sqlcmd against
-- LAPTOP-20MJVLDK\RSPETSTOPQ12026updated - see supabase_warehouses_items_tables.sql for why
-- Categories is portal-only and not kept in sync automatically). Run this in the Supabase SQL
-- editor any time you want to pull a fresh snapshot of the local flags; safe to re-run, upserts
-- by "Code". Requires public."Categories" to already exist (supabase_warehouses_items_tables.sql).
insert into public."Categories" ("Code", "Description", "IsProductionCategory") values
  ('ACCESSORIES', 'Fish Accessories and Equipment', false),
  ('AQUARIUM', 'Aquarium', true),
  ('Aquarium Lights', 'Aquarium Lights', false),
  ('AQUASCAPE', 'Aquascape materials', false),
  ('AVAILABLE FISH', 'AVAILABLE FISH', false),
  ('CICHLIDS', 'CICHLIDS', false),
  ('CUSTOM-AQUARIUM', 'Custom Aquarium', false),
  ('CUSTOMER-STICKER', 'Customer Sticker', false),
  ('CUSTOMIZED ITEM', 'CUSTOMIZED ITEM', false),
  ('CUSTOMIZED-ITEM', 'Customized Item', false),
  ('CUSTOM-MEDIAS', 'Custom Medias', false),
  ('CUSTOM-OVERFLOWBOX', 'Custom Overflow Box', false),
  ('CUSTOM-PIPINGS', 'Custom Pipings', false),
  ('CUSTOM-STAND', 'Custom Stand', false),
  ('CUSTOM-STICKER', 'Custom Sticker', false),
  ('CUSTOM-SUMP', 'Custom Sump', false),
  ('CUSTOM-TOPCOVER', 'Custom TopCover', false),
  ('DIVIDER', 'Divider', false),
  ('FEEDERS', 'Feeders', false),
  ('FILTER MEDIAS', 'Filter Medias', false),
  ('FILTRATION', 'Filtration', false),
  ('FISH', 'Fish and Aquatic Animals', false),
  ('FOOD', 'Fish Foods', false),
  ('LIGHTS', 'Aquarium Lights', false),
  ('MEDIAS', 'Filter Medias', false),
  ('MEDICINE', 'Medicines', false),
  ('MEDICINES', 'Medicines', false),
  ('NULL', 'NULL', false),
  ('PLANTS', 'Plants', false),
  ('PRODUCTION ITEM', 'PRODUCTION ITEM', false),
  ('PUMP', 'Pumps', false),
  ('SET', 'SET', false),
  ('STAND', 'Stand', true),
  ('STICKER', 'STICKER', false),
  ('STICKERS', 'Sticker', false),
  ('STONE', 'STONE', false),
  ('SUMP', 'Sump glass Filtration', true),
  ('TETRA', 'TETRA', false)
on conflict ("Code") do update
  set "Description" = excluded."Description",
      "IsProductionCategory" = excluded."IsProductionCategory";
