-- TEST ONLY: dummy In Stock serials for custom tanks and custom stands at Amaya - per "can you create
-- me a dummy serial for testing only custom tank and custom stand for amaya". Lets Ready to Ship's
-- serial picker (Online Orders, supabase_online_order_to_ship_serials.sql) be tested without real
-- tagged units.
--
-- Creates 2 serials for every custom aquarium / custom stand item and each of its Pancake variants,
-- because the picker only offers serials whose ItemCode AND VariantCode match the order line. Every
-- row is tagged SourceDocumentNo = 'TEST-DUMMY-SERIAL' and SerialNo 'TEST-...' so step 4 removes them
-- all. Location is the Amaya warehouse's exact name, since the picker filters on the logged-in user's
-- warehouse name.
--
-- Run each step on its own in the Supabase SQL editor.

-- 1. PREVIEW - the Amaya location name and what would be created (nothing is written).
select w."Name" as amaya_location from public."Warehouses" w where w."Name" ilike '%amaya%';

with custom_items as (
  -- each variant of a custom aquarium / custom stand item
  select coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode") as item_code,
         v."VariationId" as variant_code,
         coalesce(nullif(trim(v."VariantName"), ''), i."Name") as description
  from public."Variants" v
  left join public."Items" i on i."Code" = coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode")
  where upper(coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode")) similar to '(CUSTOM-AQUARIUM|CUSTOM_AQUARIUM|CUSTOM-STAND|CUSTOM_STAND)%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ilike '%custom%aquarium%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ilike '%custom%stand%'
  union
  -- the item itself with no variant (lines without a VariationId)
  select i."Code", null, i."Name"
  from public."Items" i
  where upper(i."Code") similar to '(CUSTOM-AQUARIUM|CUSTOM_AQUARIUM|CUSTOM-STAND|CUSTOM_STAND)%'
     or coalesce(i."Name", '') ilike '%custom%aquarium%'
     or coalesce(i."Name", '') ilike '%custom%stand%'
)
select item_code, variant_code, description, 2 as serials_to_create
from custom_items
order by item_code, variant_code nulls first;

-- 2. CREATE - 2 dummy In Stock serials per row from step 1, at Amaya.
with amaya as (
  select w."Name" from public."Warehouses" w where w."Name" ilike '%amaya%' order by length(w."Name") limit 1
), custom_items as (
  select coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode") as item_code,
         v."VariationId" as variant_code,
         coalesce(nullif(trim(v."VariantName"), ''), i."Name") as description
  from public."Variants" v
  left join public."Items" i on i."Code" = coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode")
  where upper(coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode")) similar to '(CUSTOM-AQUARIUM|CUSTOM_AQUARIUM|CUSTOM-STAND|CUSTOM_STAND)%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ilike '%custom%aquarium%'
     or (coalesce(i."Name", '') || ' ' || coalesce(v."VariantName", '')) ilike '%custom%stand%'
  union
  select i."Code", null, i."Name"
  from public."Items" i
  where upper(i."Code") similar to '(CUSTOM-AQUARIUM|CUSTOM_AQUARIUM|CUSTOM-STAND|CUSTOM_STAND)%'
     or coalesce(i."Name", '') ilike '%custom%aquarium%'
     or coalesce(i."Name", '') ilike '%custom%stand%'
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
cross join generate_series(1, 2) as n
where (select "Name" from amaya) is not null
on conflict ("SerialNo") do nothing;

-- 3. CHECK - the dummy serials now in stock.
select "SerialNo", "ItemCode", "VariantCode", "Location", "Status", "SoldOnlineOrderId"
from public."ItemSerialTracking"
where "SourceDocumentNo" = 'TEST-DUMMY-SERIAL'
order by "ItemCode", "VariantCode", "SerialNo";

-- 4. CLEAN UP when testing is finished - removes every dummy serial, including any a test order
--    claimed (Sold). Run on its own.
-- delete from public."ItemSerialTracking" where "SourceDocumentNo" = 'TEST-DUMMY-SERIAL';
