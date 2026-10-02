-- Cabinet / Canopy pricing (2026-10-02): 18mm laminated plywood settings in AquariumExtraPricingSetup,
-- editable from the portal's Pricing Setup page ("Aquarium Extras Pricing"). Read by
-- custom-aquarium-calculator.js (computePlywoodPanels) and Alice (chatbot-engine.ts). Priced per sq ft:
--
--   price = panel area (sq ft) x ('Plywood Sheet 18mm' / 32) x (1 + 'Plywood Waste %' / 100) x 'Plywood Markup'
--           never below 'Plywood Minimum', + door (front) area x 'Door Hardware per sq ft' (cabinet only)
--
--   'Plywood Sheet 18mm'    pesos per 4x8ft sheet
--   'Plywood Waste %'       percent, e.g. 15 = 15% cutting loss
--   'Plywood Markup'        multiplier for the CABINET, e.g. 1.6 (~P224/sq ft with the values below) - not pesos
--   'Canopy Markup'         multiplier for the CANOPY, e.g. 1.3 (~P182/sq ft) - simpler build than a cabinet
--   'Plywood Minimum'       pesos, least charged per cabinet and per canopy
--   'Door Hardware per sq ft' pesos per sq ft of door area (hinges + handles), so bigger doors cost more
--                           (60 ~ P250 for a typical 18" x 33" door)
--
-- Cabinet Type "Aluminum" (4mm ACP aluminum composite panel on the steel stand, aluminum-framed doors)
-- uses the same formula with its own keys: 'Aluminum ACP Sheet 4mm' (pesos per 4x8ft sheet),
-- 'Aluminum Waste %', 'Aluminum Markup' (cabinet), 'Aluminum Canopy Markup', 'Aluminum Minimum',
-- 'Aluminum Door Hardware per sq ft'. The chosen type applies to both cabinet and canopy.
--
-- Run AFTER supabase_aquarium_extra_pricing.sql. Safe to re-run (only inserts missing keys; the
-- markup is moved from the first draft's 1.22 to 1.6 and the sheet price from 3600 to 3900, only if
-- they were never edited). Removes the earlier flat per-door 'Cabinet Door Hardware' key.

insert into public."AquariumExtraPricingSetup" ("FeatureKey", "Price")
select v.key, v.price
from (values
  ('Plywood Sheet 18mm', 3900.00),
  ('Plywood Waste %', 15.00),
  ('Plywood Markup', 1.60),
  ('Canopy Markup', 1.30),
  ('Plywood Minimum', 2200.00),
  ('Door Hardware per sq ft', 60.00),
  ('Aluminum ACP Sheet 4mm', 7000.00),
  ('Aluminum Waste %', 10.00),
  ('Aluminum Markup', 1.80),
  ('Aluminum Canopy Markup', 1.50),
  ('Aluminum Minimum', 3000.00),
  ('Aluminum Door Hardware per sq ft', 60.00)
) as v(key, price)
where not exists (select 1 from public."AquariumExtraPricingSetup" s where s."FeatureKey" = v.key);

update public."AquariumExtraPricingSetup"
set "Price" = 1.60, "UpdatedAtUtc" = now()
where "FeatureKey" = 'Plywood Markup' and "Price" = 1.22;

update public."AquariumExtraPricingSetup"
set "Price" = 3900.00, "UpdatedAtUtc" = now()
where "FeatureKey" = 'Plywood Sheet 18mm' and "Price" = 3600;

delete from public."AquariumExtraPricingSetup" where "FeatureKey" = 'Cabinet Door Hardware';

select "FeatureKey", "Price" from public."AquariumExtraPricingSetup" order by "FeatureKey";
