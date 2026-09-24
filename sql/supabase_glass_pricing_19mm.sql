-- Adds the 19mm (3/4") glass price - 2000 per sq ft, per direct request - to GlassPricingSetup so it
-- shows on the portal's Pricing Setup page and can be edited there like the other thicknesses.
--
-- Optional: the calculators (custom-aquarium-calculator.js) and the AI bot already fall back to a
-- built-in 2000 for 19mm, so quotes are correct without this. Run it only if you want to change
-- the price from Pricing Setup instead of in code.
--
-- 19mm is only offered on the standalone Sticker calculator's Glass type, not on aquariums.
-- Safe to re-run: it leaves an existing 19mm price (e.g. one you already edited) alone.

insert into public."GlassPricingSetup" ("Uom", "Thickness", "PricePerSqFt", "UpdatedBy")
select 'MM', '19', 2000.00, 'system'
where not exists (
  select 1 from public."GlassPricingSetup" where upper("Uom") = 'MM' and "Thickness" = '19'
);

select "Thickness", "PricePerSqFt" from public."GlassPricingSetup" where upper("Uom") = 'MM' order by ("Thickness")::int;
