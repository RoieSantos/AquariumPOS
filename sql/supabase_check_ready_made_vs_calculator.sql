-- READ-ONLY. Do ready-made aquariums match the custom calculator? Per "if the customer buys the aquarium and
-- then later on use the calculator to buy the same aquarium size and found out the price mismatch".
-- Nothing is changed. Run it before and after a price increase.
--
-- One row per active AQUARIUM item, biggest gap first. Size and glass are read from the item's name, then its
-- description: "72x18x18" (inches) and "6MM". The calculator price is its plain "Aquarium only" price at that
-- size and glass, using live rates: glass area x rate (small 6mm rate, 12mm surcharges), doubled when tempered,
-- x 2.4 when the name says AIO, rounded to the nearest 10 from P1,000. Rimless changes only the glass safety
-- rules in the calculator, not the price, so it is priced like any other tank.
--
--   status        OK (within tolerance_pct) / CALCULATOR CHEAPER / CALCULATOR DEARER / CAN'T COMPARE
--   item_price    what customers are quoted: coalesce(RetailPrice, Price), same as Order Now and Alice
--   gap_pct       calculator vs item (negative = the calculator is cheaper)
--
-- calc_price is the price from the RATES, before the exact-size match (supabase_ready_made_price_match.sql), so
-- this still shows how far the rates are from your ready-made prices.
--
-- NOT modelled, so check these rows by hand: a name saying low iron, sump, stand or a set (flagged in "note"), and the calculator's automatic glass upgrade for sizes where the thickness in the name isn't safe.

with params as (
  select 2.0::numeric as tolerance_pct
),
extra as (
  select
    coalesce(max("Price") filter (where "FeatureKey" = 'Small 6mm Glass per sq ft'), 117) as small_6mm,
    coalesce(max("Price") filter (where "FeatureKey" = '12mm Surcharge 170+ gal per sq ft'), 110) as sur_170,
    coalesce(max("Price") filter (where "FeatureKey" = '12mm Surcharge 300+ gal per sq ft'), 145) as sur_300
  from public."AquariumExtraPricingSetup"
),
glass as (
  select trim("Thickness") as mm, max("PricePerSqFt") as rate
  from public."GlassPricingSetup"
  where upper(coalesce("Uom", 'MM')) = 'MM'
  group by 1
),
items as (
  select i."Code" as code, i."Name" as name,
         coalesce(i."RetailPrice", i."Price") as item_price,
         coalesce(i."Name", '') || ' ' || coalesce(i."Description", '') as txt
  from public."Items" i
  where i."IsActive" is true
    and upper(trim(coalesce(i."CategoryCode", ''))) = 'AQUARIUM'
),
parsed as (
  select it.*,
         regexp_match(it.txt, '(\d+(?:\.\d+)?)\s*[xX×]\s*(\d+(?:\.\d+)?)\s*[xX×]\s*(\d+(?:\.\d+)?)') as dims,
         (regexp_match(it.txt, '(\d+)\s*[mM][mM]'))[1] as mm,
         it.txt ~* 'tempered' as named_tempered,
         (regexp_match(it.txt, '(?i)(low[ -]?iron|sump|stand\M|complete|\mset\M)'))[1] as special
  from items it
),
sized as (
  select p.*,
         p.dims[1]::numeric as l, p.dims[2]::numeric as w, p.dims[3]::numeric as h,
         p.dims[1]::numeric * p.dims[2]::numeric * p.dims[3]::numeric / 231 as gallons,
         (2 * p.dims[1]::numeric * p.dims[3]::numeric + 2 * p.dims[2]::numeric * p.dims[3]::numeric
           + p.dims[1]::numeric * p.dims[2]::numeric) / 144 as area_sqft
  from parsed p
),
rated as (
  select s.*, g.rate as glass_rate,
         -- The calculator forces tempered from 36in width or height.
         (s.named_tempered or s.w >= 36 or s.h >= 36) as tempered,
         case when s.gallons < 90 and s.mm = '6' then e.small_6mm
              when s.gallons >= 300 and s.mm = '12' then g.rate + e.sur_300
              when s.gallons >= 170 and s.mm = '12' then g.rate + e.sur_170
              else g.rate end as rate_used
  from sized s
  cross join extra e
  left join glass g on g.mm = s.mm
),
priced as (
  select r.*,
         case when r.area_sqft is null or r.rate_used is null then null
              else r.area_sqft * r.rate_used * case when r.tempered then 2 else 1 end
                   * case when r.txt ~* '\maio\M' then 2.4 else 1 end end as raw_calc
  from rated r
),
final as (
  select p.*,
         case when p.raw_calc is null then null
              when p.raw_calc >= 1000 then round(p.raw_calc / 10) * 10
              else round(p.raw_calc, 2) end as calc_price
  from priced p
)
select
  case when f.calc_price is null or coalesce(f.item_price, 0) <= 0 then 'CAN''T COMPARE'
       when abs(f.calc_price - f.item_price) / f.item_price * 100 <= (select tolerance_pct from params) then 'OK'
       when f.calc_price < f.item_price then 'CALCULATOR CHEAPER'
       else 'CALCULATOR DEARER' end as status,
  f.code,
  f.name,
  case when f.dims is null then null else f.l || 'x' || f.w || 'x' || f.h end as size_in,
  round(f.gallons, 1) as gallons,
  f.mm as glass_mm,
  f.tempered,
  round(f.item_price, 2) as item_price,
  f.calc_price,
  round(f.calc_price - f.item_price, 2) as gap_pesos,
  case when coalesce(f.item_price, 0) > 0
       then round((f.calc_price - f.item_price) / f.item_price * 100, 1) end as gap_pct,
  concat_ws('; ',
    case when f.dims is null then 'no LxWxH size found in name or description' end,
    case when f.mm is null then 'no glass thickness found' end,
    case when f.mm is not null and f.glass_rate is null then 'no glass rate for ' || f.mm || 'mm' end,
    case when coalesce(f.item_price, 0) <= 0 then 'no item price' end,
    case when f.special is not null then 'name says "' || f.special || '" - calculator price here is plain aquarium only' end
  ) as note
from final f
order by
  case when f.calc_price is null or coalesce(f.item_price, 0) <= 0 then 1 else 0 end,
  abs(f.calc_price - f.item_price) / nullif(f.item_price, 0) desc nulls last,
  f.name;
