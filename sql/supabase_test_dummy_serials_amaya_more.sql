-- TEST ONLY: more dummy In Stock serials at Amaya - per "can you give me more test serials for
-- CUSTOM-TOPcover / CUSTOM-AQUARIUM and CUSTOM-STAND".
--
-- Same approach as supabase_test_dummy_serials_amaya.sql (which made serials #1-2 per item/variant for
-- custom aquariums and stands): this adds serials #3-7 (5 more) for every custom aquarium, custom stand
-- AND custom top cover item and each of its variants - the serial picker only offers serials whose
-- ItemCode AND VariantCode match the order line. Same tags (SourceDocumentNo 'TEST-DUMMY-SERIAL',
-- SerialNo 'TEST-...'), so the clean-up in step 4 removes these too. Safe to re-run (existing serials
-- are skipped).
--
-- Run each step on its own in the Supabase SQL editor.

-- 1. PREVIEW - the items/variants that get 5 more serials each (nothing is written).
with custom_items as (
  select coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode") as item_code,
         v."VariationId" as variant_code,
         coalesce(nullif(trim(v."VariantName"), ''), i."Name") as description
  from public."Variants" v
  left join public."Items" i on i."Code" = coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode")
  where upper(coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode")) similar to '(CUSTOM-AQUARIUM|CUSTOM_AQUARIUM|CUSTOM-STAND|CUSTOM_STAND|CUSTOM-TOP%|CUSTOM_TOP%)%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ilike '%custom%aquarium%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ilike '%custom%stand%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ~* 'custom.*top[[:space:]_-]*cover'
  union
  select i."Code", null, i."Name"
  from public."Items" i
  where upper(i."Code") similar to '(CUSTOM-AQUARIUM|CUSTOM_AQUARIUM|CUSTOM-STAND|CUSTOM_STAND|CUSTOM-TOP%|CUSTOM_TOP%)%'
     or coalesce(i."Name", '') ilike '%custom%aquarium%'
     or coalesce(i."Name", '') ilike '%custom%stand%'
     or coalesce(i."Name", '') ~* 'custom.*top[[:space:]_-]*cover'
)
select item_code, variant_code, description, 5 as serials_to_add
from custom_items
order by item_code, variant_code nulls first;

-- 2. CREATE - serials #3-7 per row from step 1, at Amaya.
with amaya as (
  select w."Name" from public."Warehouses" w where w."Name" ilike '%amaya%' order by length(w."Name") limit 1
), custom_items as (
  select coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode") as item_code,
         v."VariationId" as variant_code,
         coalesce(nullif(trim(v."VariantName"), ''), i."Name") as description
  from public."Variants" v
  left join public."Items" i on i."Code" = coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode")
  where upper(coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode")) similar to '(CUSTOM-AQUARIUM|CUSTOM_AQUARIUM|CUSTOM-STAND|CUSTOM_STAND|CUSTOM-TOP%|CUSTOM_TOP%)%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ilike '%custom%aquarium%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ilike '%custom%stand%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ~* 'custom.*top[[:space:]_-]*cover'
  union
  select i."Code", null, i."Name"
  from public."Items" i
  where upper(i."Code") similar to '(CUSTOM-AQUARIUM|CUSTOM_AQUARIUM|CUSTOM-STAND|CUSTOM_STAND|CUSTOM-TOP%|CUSTOM_TOP%)%'
     or coalesce(i."Name", '') ilike '%custom%aquarium%'
     or coalesce(i."Name", '') ilike '%custom%stand%'
     or coalesce(i."Name", '') ~* 'custom.*top[[:space:]_-]*cover'
)
insert into public."ItemSerialTracking"
  ("SerialNo", "ItemCode", "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedBy", "VariantCode")
select
  'TEST-' || upper(left(md5(c.item_code || '|' || coalesce(c.variant_code, '') || '|' || n), 8)),
  c.item_code,
  left('TEST - ' || coalesce(c.description, c.item_code), 255),
  (select "Name" from amaya),
  'IN_STOCK',
  'TEST-DUMMY-SERIAL',
  'test-script',
  c.variant_code
from custom_items c
cross join generate_series(3, 7) as n
where (select "Name" from amaya) is not null
on conflict ("SerialNo") do nothing;

-- 3. CHECK - in-stock dummy serials per item/variant.
select "ItemCode", "VariantCode", count(*) filter (where "Status" = 'IN_STOCK') as in_stock, count(*) as total
from public."ItemSerialTracking"
where "SourceDocumentNo" = 'TEST-DUMMY-SERIAL'
group by "ItemCode", "VariantCode"
order by "ItemCode", "VariantCode";

-- 4. CLEAN UP when testing is finished - removes every dummy serial (from both test scripts), including
--    any a test order claimed. Run on its own.
-- delete from public."ItemSerialTracking" where "SourceDocumentNo" = 'TEST-DUMMY-SERIAL';
