-- Adds "Acrylic Sump Cover" to the standalone Sticker/Accessory catalog (public."StickerPricingSetup").
-- Unlike the other rows, its PricePerSqFt column holds a MARKUP MULTIPLIER, not pesos:
--   Acrylic Sump Cover price per sq ft = Acrylic's PricePerSqFt x this value
-- (custom-aquarium-calculator.js / chatbot-engine.ts stickerPricePerSqFt), so an Acrylic price change
-- carries over automatically. Edit the markup from the portal's Pricing Setup page.
--
-- Safe to re-run: only inserts if the row doesn't exist yet (won't stomp an edited markup).
insert into public."StickerPricingSetup" ("StickerType", "Thickness", "PricePerSqFt")
select 'Acrylic Sump Cover', null, 1.50
where not exists (
  select 1 from public."StickerPricingSetup" s where s."StickerType" = 'Acrylic Sump Cover'
);

select "StickerType", "Thickness", "PricePerSqFt"
from public."StickerPricingSetup"
where "StickerType" in ('Acrylic', 'Acrylic Sump Cover')
order by "StickerType";
