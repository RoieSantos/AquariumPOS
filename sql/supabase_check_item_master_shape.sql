-- READ-ONLY check before the portal takes over products from Pancake (New Item with category prefix +
-- next number, picture upload, POS pulling products from the portal).
--
-- Changes nothing. One result: section / item / detail.
--   1 Prefix per category - each category's code prefixes (FD in FD-009), how many items, highest number
--   2 Odd codes           - item codes not shaped PREFIX-123 (count per category + examples)
--   3 Shared prefixes     - a prefix used by more than one category (next-number must not collide)
--   4 Variants per item   - how many items have 0 / 1 / 2+ variants
--   5 Variant examples    - multi-variant items: item code vs each variant's SKU / name / price
--   6 Picture hosts       - where Items.Images / Variants.Images point (Pancake CDN, etc.)
--   7 Categories          - categories used on items but missing from the Categories table, and the reverse
--   8 Active flag         - Items.IsActive values

with codes as (
  select i."Code" as code, coalesce(nullif(trim(i."CategoryCode"), ''), '(none)') as cat,
         (regexp_match(i."Code", '^([A-Za-z]+)-([0-9]+)$')) as m
  from public."Items" i
),
prefixes as (
  select cat, upper(m[1]) as prefix, count(*) as n, max(m[2]::int) as max_no, max(length(m[2])) as digits
  from codes where m is not null
  group by cat, upper(m[1])
),
vcount as (
  select i."Code", (select count(*) from public."Variants" v where v."ItemCode" = i."Code") as n
  from public."Items" i
)

select '1 Prefix per category' as section, p.cat || ' / ' || p.prefix as item,
       p.n || ' items; highest ' || p.prefix || '-' || lpad(p.max_no::text, p.digits, '0') as detail
from prefixes p

union all
select '2 Odd codes', cat,
       count(*) || ' items, e.g. ' || string_agg(code, ', ' order by code) filter (where rn <= 8)
from (select c.*, row_number() over (partition by cat order by code) as rn from codes c where m is null) x
group by cat

union all
select '3 Shared prefixes', prefix, string_agg(cat || ' (' || n || ')', ', ' order by n desc)
from prefixes group by prefix having count(*) > 1

union all
select '4 Variants per item', case when n = 0 then '0 variants' when n = 1 then '1 variant' else '2+ variants' end,
       count(*) || ' items'
from vcount group by 2

union all
select '5 Variant examples', x."ItemCode" || ' -> ' || coalesce(x."SKU", '(no sku)'),
       coalesce(x."VariantName", '?') || '; price ' || coalesce(x."Price"::text, '?') || '; id ' || x."VariationId"
from (
  select v.*, dense_rank() over (order by v."ItemCode") as item_rank
  from public."Variants" v
  where v."ItemCode" in (select "Code" from vcount where n > 1)
) x
where x.item_rank <= 6

union all
select '6 Picture hosts', src || ' ' || coalesce(substring(img from '^https?://([^/]+)'), '(not a URL: ' || left(img, 40) || ')'),
       count(*) || ' rows'
from (
  select 'item' as src, "Images" as img from public."Items" where nullif(trim("Images"), '') is not null
  union all
  select 'variant', "Images" from public."Variants" where nullif(trim("Images"), '') is not null
) x
group by 2

union all
select '7 Categories', 'on items, not in Categories table',
       coalesce(string_agg(distinct i."CategoryCode", ', '), 'none')
from public."Items" i
where nullif(trim(i."CategoryCode"), '') is not null
  and not exists (select 1 from public."Categories" c where c."Code" = i."CategoryCode")
union all
select '7 Categories', 'in Categories table, no items',
       coalesce(string_agg(c."Code", ', '), 'none')
from public."Categories" c
where not exists (select 1 from public."Items" i where i."CategoryCode" = c."Code")

union all
select '8 Active flag', coalesce("IsActive"::text, '(null)'), count(*) || ' items'
from public."Items" group by "IsActive"

order by 1, 2;
