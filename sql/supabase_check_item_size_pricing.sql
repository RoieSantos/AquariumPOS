-- =============================================================================
-- READ-ONLY check: what's set up for size-based pricing (sql/supabase_item_size_pricing.sql).
-- One result, one row per line, grouped by "section":
--   1 scales    - each size scale, its Round To and how many sizes / products it has
--   2 tiers     - each size on each scale (+% / +₱)
--   3 prices    - every product on a scale x every size, with the price staff will see
--                 (Standard = the product's normal price, then each size from the formula)
--   4 summary   - totals
-- Run AFTER supabase_item_size_pricing.sql. Safe to run any time; changes nothing.
-- =============================================================================
with scales as (
  select s."Code" as scale_code, s."Name" as scale_name, s."RoundTo" as round_to, s."UpdatedAtUtc", s."UpdatedBy"
  from public."SizePriceScales" s
),
tiers as (
  select t."ScaleCode" as scale_code, t."SortOrder" as sort_order, t."SizeLabel" as size_label,
         t."MarkupPercent" as pct, t."MarkupAmount" as amt
  from public."SizePriceTiers" t
),
items as (
  select i."Code" as item_code,
         coalesce(nullif(trim(i."Name"), ''), i."Description", i."Code") as item_name,
         i."SizeScaleCode" as scale_code,
         coalesce(i."RetailPrice", i."Price", 0) as base_price,
         i."IsActive" as is_active
  from public."Items" i
  where i."SizeScaleCode" is not null
),
rows as (
  -- 1 scales
  select 1 as section_no, 'scales' as section, sc.scale_code, sc.scale_name,
         null::text as item_code, null::text as item_name, null::text as size_label,
         null::numeric as markup_percent, null::numeric as markup_amount, sc.round_to,
         null::numeric as base_price, null::numeric as size_price, null::numeric as increase,
         format('%s size(s), %s product(s); updated %s by %s',
                (select count(*) from tiers t where t.scale_code = sc.scale_code),
                (select count(*) from items i where i.scale_code = sc.scale_code),
                to_char(sc."UpdatedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'),
                coalesce(sc."UpdatedBy", '-')) as note,
         0 as sort_order
  from scales sc

  union all
  -- 2 tiers
  select 2, 'tiers', t.scale_code, sc.scale_name, null, null, t.size_label,
         t.pct, t.amt, sc.round_to, null, null, null,
         format('Example on P10,000: P%s', to_char(public._size_tier_price(10000, t.pct, t.amt, sc.round_to), 'FM999,999,990.00')),
         t.sort_order
  from tiers t join scales sc on sc.scale_code = t.scale_code

  union all
  -- 3 prices: Standard row per product
  select 3, 'prices', i.scale_code, sc.scale_name, i.item_code, i.item_name, 'Standard',
         0, 0, sc.round_to, i.base_price, i.base_price, 0,
         case when i.is_active is false then 'Product is INACTIVE' when i.base_price = 0 then 'Product has NO price - every size will be P0' else null end,
         0
  from items i join scales sc on sc.scale_code = i.scale_code

  union all
  -- 3 prices: one row per product x size
  select 3, 'prices', i.scale_code, sc.scale_name, i.item_code, i.item_name, t.size_label,
         t.pct, t.amt, sc.round_to, i.base_price,
         public._size_tier_price(i.base_price, t.pct, t.amt, sc.round_to),
         public._size_tier_price(i.base_price, t.pct, t.amt, sc.round_to) - i.base_price,
         null,
         t.sort_order
  from items i
  join scales sc on sc.scale_code = i.scale_code
  join tiers t on t.scale_code = i.scale_code

  union all
  -- products pointing at a scale that no longer exists (shouldn't happen)
  select 3, 'prices', i.scale_code, null, i.item_code, i.item_name, null, null, null, null, i.base_price, null, null,
         'Scale not found - this product gets no size picker', 0
  from items i
  where not exists (select 1 from scales sc where sc.scale_code = i.scale_code)

  union all
  -- 4 summary
  select 4, 'summary', null, null, null, null, null, null, null, null, null, null, null,
         format('%s scale(s), %s size(s), %s product(s) on size pricing',
                (select count(*) from scales), (select count(*) from tiers), (select count(*) from items)),
         0
)
select section, scale_code, scale_name, item_code, item_name, size_label,
       markup_percent, markup_amount, round_to, base_price, size_price, increase, note
from rows
order by section_no, scale_name nulls first, item_name nulls first, sort_order;
