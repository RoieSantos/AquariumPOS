-- One-time (re-runnable) addition of Plywood to the standalone Sticker/Accessory catalog
-- (public."StickerPricingSetup" - see supabase_pricing_setup_tables.sql), per direct request:
-- 2 plywood types (Marine, Laminated) x 2 thicknesses (6mm, 18mm) each. Matches the existing
-- Rubber Matting shape (StickerType + Thickness, priced per sqft) rather than the flat types.
--
-- Run this in the Supabase SQL editor. Uses the same "insert if this exact
-- StickerType+Thickness row doesn't already exist" guard as the seed block in
-- supabase_pricing_setup_tables.sql, so it's safe to re-run and won't stomp prices already
-- edited via the portal's Pricing Setup page.
insert into public."StickerPricingSetup" ("StickerType", "Thickness", "PricePerSqFt")
select v.sticker_type, v.thickness, v.price
from (values
  ('Marine Plywood', '6', 90.00),
  ('Marine Plywood', '18', 185.00),
  ('Laminated Plywood', '6', 125.00),
  ('Laminated Plywood', '18', 210.00)
) as v(sticker_type, thickness, price)
where not exists (
  select 1 from public."StickerPricingSetup" s
  where s."StickerType" = v.sticker_type and s."Thickness" = v.thickness
);
