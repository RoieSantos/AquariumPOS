-- Overhead Sump "Custom 1/2 Pipe with Separate Drain" (item A-070) - the aquarium calculators
-- (Order Now, staff/POS calculator, Alice) now read its price LIVE from the item instead of a
-- hardcoded 790. Rather than a new RPC every caller would have to load, it's appended as one more
-- row ('Piping Separate Drain') of public_get_aquarium_extra_pricing, which all of them (and the
-- POS's offline pricing sync, SyncAquariumExtraPricingFromSupabaseAsync) already fetch.
--
-- Change the price on the item (Items page, A-070) - NOT on Pricing Setup; this row is not stored
-- in AquariumExtraPricingSetup and doesn't show there. If A-070 is missing/inactive the row is
-- left out and the calculators fall back to 790.
--
-- Run AFTER supabase_aquarium_extra_pricing.sql. Safe to re-run (replaces the function only).

create or replace function public.public_get_aquarium_extra_pricing()
returns table(feature_key text, price numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "FeatureKey"::text, "Price"
  from public."AquariumExtraPricingSetup"
  where "FeatureKey" <> 'Piping Separate Drain'
  union all
  select 'Piping Separate Drain'::text, i."Price"
  from public."Items" i
  where i."Code" = 'A-070'
    and i."IsActive" is true
    and i."Price" is not null
  order by 1;
$$;

grant execute on function public.public_get_aquarium_extra_pricing() to anon;

-- Check: should list Hole, the plywood/aluminum keys, and 'Piping Separate Drain' = A-070's price.
select * from public.public_get_aquarium_extra_pricing();
