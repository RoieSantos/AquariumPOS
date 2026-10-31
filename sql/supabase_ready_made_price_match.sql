-- One tank size, one price - per "the customer buys the aquarium and then later on use the calculator to buy
-- the same aquarium size and found out the price mismatch". When a customer enters the exact size and glass of
-- an active ready-made aquarium, the calculators now use that item's own price for the tank.
--
-- Like 'Piping Separate Drain' (supabase_piping_separate_drain_price.sql), the prices are appended as more rows
-- of public_get_aquarium_extra_pricing, which every calculator (Order Now, portal, POS offline cache, Alice)
-- already fetches. These rows are read LIVE from Items, so a price change or price increase on the item applies
-- by itself. They are not stored in AquariumExtraPricingSetup, and don't show on Pricing Setup or Price Increase.
--
-- Row key: ReadyMade|<longer side>x<shorter side>x<height>|<glass mm>|<AIO 0/1>|<tempered 0/1>
-- Size and glass come from the item's name, then its description, e.g. "STANDARD-100G (72x18x18in, 6MM GLASS)".
-- Left out: inactive items, no price, no readable size or glass, and items naming low iron, a sump, a stand or a
-- set. Two items with the same key (e.g. a duplicate) use the higher price.
--
-- Run AFTER supabase_price_change_batches.sql. Safe to re-run (replaces the function only). Quotes change as soon
-- as the updated calculator code is live, not when this runs.

create or replace function public.public_get_aquarium_extra_pricing()
returns table(feature_key text, price numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with items as (
    select coalesce(i."RetailPrice", i."Price") as price,
           coalesce(i."Name", '') || ' ' || coalesce(i."Description", '') as txt
    from public."Items" i
    where i."IsActive" is true
      and upper(trim(coalesce(i."CategoryCode", ''))) = 'AQUARIUM'
      and coalesce(i."RetailPrice", i."Price") > 0
  ),
  parsed as (
    select it.price, it.txt,
           regexp_match(it.txt, '(\d+(?:\.\d+)?)\s*[xX×]\s*(\d+(?:\.\d+)?)\s*[xX×]\s*(\d+(?:\.\d+)?)') as dims,
           (regexp_match(it.txt, '(\d+)\s*[mM][mM]'))[1] as mm
    from items it
    where it.txt !~* '(low[ -]?iron|sump|stand\M|complete|\mset\M)'
  ),
  sized as (
    select p.price, p.mm,
           round(greatest(p.dims[1]::numeric, p.dims[2]::numeric), 1) as long_side,
           round(least(p.dims[1]::numeric, p.dims[2]::numeric), 1) as short_side,
           round(p.dims[3]::numeric, 1) as height,
           p.txt ~* '\maio\M' as aio,
           -- The calculator forces tempered from 36in width or height.
           (p.txt ~* 'tempered' or p.dims[2]::numeric >= 36 or p.dims[3]::numeric >= 36) as tempered
    from parsed p
    where p.dims is not null and p.mm is not null
  )
  select "FeatureKey"::text, "Price"
  from public."AquariumExtraPricingSetup"
  where "FeatureKey" <> 'Piping Separate Drain'
  union all
  select 'Piping Separate Drain'::text, i."Price"
  from public."Items" i
  where i."Code" = 'A-070'
    and i."IsActive" is true
    and i."Price" is not null
  union all
  select 'ReadyMade|' || trim_scale(s.long_side) || 'x' || trim_scale(s.short_side) || 'x' || trim_scale(s.height)
           || '|' || s.mm || '|' || case when s.aio then '1' else '0' end || '|' || case when s.tempered then '1' else '0' end,
         max(s.price)
  from sized s
  group by s.long_side, s.short_side, s.height, s.mm, s.aio, s.tempered
  order by 1;
$$;

grant execute on function public.public_get_aquarium_extra_pricing() to anon;

notify pgrst, 'reload schema';

-- Check - ONE result: the ready-made rows the calculators will match.
select * from public.public_get_aquarium_extra_pricing() where feature_key like 'ReadyMade|%';
