-- Custom sump dividers + acrylic top drawer: Pricing Setup rows (Aquarium Extras Pricing).
--
-- 'Sump Divider Markup'       - multiplier on sump width x divider height x sump glass rate
-- 'Top Drawer Acrylic Markup' - multiplier on the drawer's 5-panel area x the live Acrylic (3mm) rate
-- 'Top Drawer Fitting'        - flat pesos per drawer: perforating and fitting. It rides on Price
--                               Increase batches automatically; the two markups are excluded there.
-- 'Sump Drain Valve'          - flat pesos per chamber for its valve, on top of the existing 'Hole' price
-- 'Sump Drain Pipe per ft'    - pesos per ft of sump length for the shared drain pipe
--
-- Run AFTER supabase_aquarium_extra_pricing.sql. Safe to re-run: existing rows are never overwritten,
-- so prices edited in Pricing Setup stay as they are.

insert into public."AquariumExtraPricingSetup" ("FeatureKey", "Price")
values
  ('Sump Divider Markup', 1.20),
  ('Top Drawer Acrylic Markup', 1.50),
  ('Top Drawer Fitting', 500.00),
  ('Sump Drain Valve', 250.00),
  ('Sump Drain Pipe per ft', 60.00)
on conflict ("FeatureKey") do nothing;

-- Check: should list the 5 rows.
select "FeatureKey", "Price"
from public."AquariumExtraPricingSetup"
where "FeatureKey" in ('Sump Divider Markup', 'Top Drawer Acrylic Markup', 'Top Drawer Fitting', 'Sump Drain Valve', 'Sump Drain Pipe per ft')
order by "FeatureKey";
