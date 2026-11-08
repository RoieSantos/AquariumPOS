-- =============================================================================
-- Puts every AROWANA product on the Monster Fish size scale (MONSTERFISH).
-- Matches the name / description / code containing "arowana" (or the "arwana" misspelling),
-- active or not. Products already on another scale are moved to Monster Fish.
--
-- Run AFTER supabase_item_size_pricing.sql and supabase_size_pricing_sample_scales.sql (which
-- creates MONSTERFISH). Safe to re-run. The desktop POS picks it up on its next 5-min sync
-- (or Sync Items).
--
-- Result: every arowana product with its Standard price and each size's price.
-- To undo for one product: Size Pricing page -> Monster Fish -> Remove.
-- =============================================================================

do $$
begin
  if not exists (select 1 from public."SizePriceScales" where "Code" = 'MONSTERFISH') then
    raise exception 'The Monster Fish scale doesn''t exist yet - run supabase_size_pricing_sample_scales.sql first.';
  end if;
end $$;

update public."Items" i
   set "SizeScaleCode" = 'MONSTERFISH'
 where concat_ws(' ', i."Name", i."Description", i."Code") ~* '(arowana|arwana)'
   and i."SizeScaleCode" is distinct from 'MONSTERFISH';

with arowana as (
  select i."Code" as item_code,
         coalesce(nullif(trim(i."Name"), ''), i."Description", i."Code") as item_name,
         coalesce(i."RetailPrice", i."Price", 0) as base_price,
         coalesce(i."IsActive", true) as is_active
  from public."Items" i
  where i."SizeScaleCode" = 'MONSTERFISH'
    and concat_ws(' ', i."Name", i."Description", i."Code") ~* '(arowana|arwana)'
),
scale as (
  select "RoundTo" as round_to from public."SizePriceScales" where "Code" = 'MONSTERFISH'
)
select a.item_code, a.item_name,
       case when not a.is_active then 'INACTIVE'
            when a.base_price = 0 then 'NO PRICE - every size is P0, set the price first'
            else 'ok' end as status,
       'Standard' as size, a.base_price as price, 0 as sort_order
from arowana a

union all
select a.item_code, a.item_name, null, t."SizeLabel",
       public._size_tier_price(a.base_price, t."MarkupPercent", t."MarkupAmount", s.round_to),
       t."SortOrder"
from arowana a
cross join scale s
join public."SizePriceTiers" t on t."ScaleCode" = 'MONSTERFISH'

order by item_name, item_code, sort_order;
