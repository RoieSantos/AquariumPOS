-- READ-ONLY check: portal variants the POS "Choose Variant" picker can't tell apart.
-- Since the portal cutover every variant's ItemCode = its main item's code, so the SKU is the only
-- thing that distinguishes them on the POS button. One result:
--   example     - the two stands from the store report (AST-001, AST-013), every variant
--   blank_sku   - variant of a multi-variant item with no SKU
--   dup_sku     - same SKU on more than one variant
--   sku_is_main - SKU equals the main item code on a multi-variant item (looks identical to its siblings)

with multi as (
  select "MainItemCode" from public."Variants" group by "MainItemCode" having count(*) > 1
)
select 'example' as section, v."MainItemCode", v."SKU", v."VariantName", v."Price", v."VariationId"
from public."Variants" v
where v."MainItemCode" in ('AST-001', 'AST-013')

union all
select 'blank_sku', v."MainItemCode", v."SKU", v."VariantName", v."Price", v."VariationId"
from public."Variants" v join multi m using ("MainItemCode")
where nullif(trim(v."SKU"), '') is null

union all
select 'dup_sku', v."MainItemCode", v."SKU", v."VariantName", v."Price", v."VariationId"
from public."Variants" v
where upper(trim(v."SKU")) in (
  select upper(trim("SKU")) from public."Variants"
  where nullif(trim("SKU"), '') is not null
  group by upper(trim("SKU")) having count(*) > 1
)

union all
select 'sku_is_main', v."MainItemCode", v."SKU", v."VariantName", v."Price", v."VariationId"
from public."Variants" v join multi m using ("MainItemCode")
where upper(trim(v."SKU")) = upper(trim(v."MainItemCode"))

order by 1, 2, 3;
