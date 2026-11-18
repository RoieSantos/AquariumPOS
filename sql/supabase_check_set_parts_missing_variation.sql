-- READ-ONLY check: set package parts that show "Not linked to a Pancake product" in Set Assembly
-- (e.g. FROK-WHITE-3FT on AO-000252). A part shows that when its package line's ItemNo has no
-- "Variants" row AND no "Items"."VariationId".
--   problem = 'no item'       -> the package line's ItemNo isn't an item code at all (fix the line on Customer Aquarium)
--   problem = 'no variation'  -> item exists but has no VariationId / Variants row (run supabase_fix_set_parts_missing_variation.sql)
with lines as (
  select l."PackageName", trim(l."ItemNo") as item_no, l."ItemName"
  from public."CompleteAquariumSetLine" l
  where trim(coalesce(l."ItemNo", '')) <> ''
)
select
  case when i."Code" is null then 'no item' else 'no variation' end as problem,
  ln."PackageName", ln.item_no, ln."ItemName",
  i."Code" as items_code, i."SKU" as items_sku, i."VariationId" as items_variation_id, i."CategoryCode",
  (select string_agg(i2."Code", ', ') from public."Items" i2
    where i."Code" is null and (upper(i2."SKU") = upper(ln.item_no) or upper(i2."Name") = upper(ln."ItemName"))) as possible_matches
from lines ln
left join public."Items" i on i."Code" = ln.item_no
where not exists (select 1 from public."Variants" v where v."MainItemCode" = ln.item_no or v."ItemCode" = ln.item_no)
  and nullif(trim(coalesce(i."VariationId", '')), '') is null
order by (ln.item_no = 'FROK-WHITE-3FT') desc, ln.item_no, ln."PackageName";
