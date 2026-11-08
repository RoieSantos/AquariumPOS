-- =============================================================================
-- SAMPLE size scales for size-based pricing (sql/supabase_item_size_pricing.sql):
--
--   MONSTERFISH - Monster Fish (arowana, flowerhorn, SHBRTG, oscar, pacu, stingray...)
--     Standard (under 8")  = the product's normal price
--     8-9"                 +10%
--     10-11"               +18%   (SHBRTG 8,500 -> 10,000)
--     12-13"               +35%
--     14-15"               +60%
--     16"+                 +100%
--     rounded to the nearest P100
--
--   MICROFISH - Micro Fish (tetras, rasboras, guppies, endlers, CPD, galaxy...)
--     Standard (juvenile, under 1")  = the product's normal price
--     Medium 1-1.5"                  +25%
--     Adult 1.5-2"                   +50%
--     Breeder / Show grade           +100%
--     rounded to the nearest P5
--
-- This ONLY creates the two scales - it does NOT put any product on them. The result lists
-- products whose name looks like a monster / micro fish so you can add them on the Size Pricing
-- page (Products on this scale -> search). Change any % on that page after running this.
--
-- Run AFTER supabase_item_size_pricing.sql. Safe to re-run: it resets these two scales' sizes
-- back to the sample values (products already on them stay on them).
-- =============================================================================

insert into public."SizePriceScales" ("Code", "Name", "RoundTo", "UpdatedAtUtc", "UpdatedBy")
values ('MONSTERFISH', 'Monster Fish', 100, now(), 'sample data'),
       ('MICROFISH', 'Micro Fish', 5, now(), 'sample data')
on conflict ("Code") do update
  set "Name" = excluded."Name", "RoundTo" = excluded."RoundTo",
      "UpdatedAtUtc" = now(), "UpdatedBy" = excluded."UpdatedBy";

delete from public."SizePriceTiers" where "ScaleCode" in ('MONSTERFISH', 'MICROFISH');

insert into public."SizePriceTiers" ("ScaleCode", "SortOrder", "SizeLabel", "MarkupPercent", "MarkupAmount")
values ('MONSTERFISH', 1, '8-9"',   10, 0),
       ('MONSTERFISH', 2, '10-11"', 18, 0),
       ('MONSTERFISH', 3, '12-13"', 35, 0),
       ('MONSTERFISH', 4, '14-15"', 60, 0),
       ('MONSTERFISH', 5, '16"+',  100, 0),
       ('MICROFISH',   1, 'Medium 1-1.5"',        25, 0),
       ('MICROFISH',   2, 'Adult 1.5-2"',         50, 0),
       ('MICROFISH',   3, 'Breeder / Show grade', 100, 0);

-- ---------------------------------------------------------------------------
-- Result: the sample price table + candidate products to put on each scale.
-- ---------------------------------------------------------------------------
with sample_bases(scale_code, example_base) as (
  values ('MONSTERFISH', 8500::numeric), ('MONSTERFISH', 3500), ('MICROFISH', 35), ('MICROFISH', 80)
),
candidates as (
  select i."Code" as item_code,
         coalesce(nullif(trim(i."Name"), ''), i."Description", i."Code") as item_name,
         coalesce(i."RetailPrice", i."Price", 0) as base_price,
         i."SizeScaleCode" as current_scale,
         case
           when i."Name" ~* '(arowana|arwana|flower ?horn|shbrtg|oscar|pacu|stingray|arapaima|datnoid|peacock bass|red ?tail cat|tiger shovel|alligator gar|spotted gar|\mgar\M|snakehead|bichir|polypterus|parrot ?fish|severum|jaguar cichlid|dovii|giant gourami)'
             then 'MONSTERFISH'
           when i."Name" ~* '(tetra|rasbora|guppy|guppies|endler|\mcpd\M|celestial pearl|galaxy|chili|ember|neon|cardinal|platy|molly|danio|killifish|pygmy cory|sparkling gourami|honey gourami|white cloud|otocinclus|\motto\M|boraras|microdevario)'
             then 'MICROFISH'
         end as suggested_scale
  from public."Items" i
  where coalesce(i."IsActive", true)
)
select 'sample prices' as section,
       s."Name" as scale, t."SizeLabel" as size,
       t."MarkupPercent" as plus_percent,
       b.example_base as example_standard_price,
       public._size_tier_price(b.example_base, t."MarkupPercent", t."MarkupAmount", s."RoundTo") as example_size_price,
       null::text as item_code, null::text as note,
       1 as sort_section, t."SortOrder" as sort_order
from public."SizePriceScales" s
join public."SizePriceTiers" t on t."ScaleCode" = s."Code"
join sample_bases b on b.scale_code = s."Code"
where s."Code" in ('MONSTERFISH', 'MICROFISH')

union all
select 'suggested products',
       case c.suggested_scale when 'MONSTERFISH' then 'Monster Fish' else 'Micro Fish' end,
       c.item_name, null, c.base_price, null, c.item_code,
       case when c.current_scale is not null then 'already on ' || c.current_scale
            when c.base_price = 0 then 'has no price - fix the price first'
            else 'add on the Size Pricing page' end,
       2, 0
from candidates c
where c.suggested_scale is not null

order by sort_section, scale, example_standard_price desc, sort_order, size;
