-- FIX: give set package parts (e.g. FROK-WHITE-3FT) a VariationId + "Variants" row, the same way
-- admin_create_item does for new portal items, so Set Assembly stops showing
-- "Not linked to a Pancake product - untick it or fix the item first."
-- Only touches items that (a) are used on a package line, (b) exist in "Items", (c) have no Variants row
-- and no VariationId. SET items are skipped. Safe to re-run (second run finds nothing to do).
-- Run AFTER checking supabase_check_set_parts_missing_variation.sql.
with targets as (
  select distinct i."Code"
  from public."CompleteAquariumSetLine" l
  join public."Items" i on i."Code" = trim(l."ItemNo")
  where coalesce(i."CategoryCode", '') <> 'SET'
    and nullif(trim(coalesce(i."VariationId", '')), '') is null
    and not exists (select 1 from public."Variants" v where v."MainItemCode" = i."Code" or v."ItemCode" = i."Code")
),
upd as (
  update public."Items" i
  set "VariationId" = gen_random_uuid()::text
  from targets t
  where i."Code" = t."Code"
  returning i.*
),
ins as (
  insert into public."Variants" ("VariationId", "MainItemCode", "ItemCode", "SKU", "VariantName", "Price", "CategoryCode", "Images")
  select u."VariationId", u."Code", u."Code", coalesce(nullif(trim(u."SKU"), ''), u."Code"),
         left(coalesce(u."Name", u."Code"), 255), u."Price", u."CategoryCode", u."Images"
  from upd u
  returning "VariationId", "ItemCode", "SKU"
)
select 'linked' as result, "ItemCode", "SKU", "VariationId" from ins
order by "ItemCode";
