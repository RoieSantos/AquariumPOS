-- READ-ONLY: why FROK Submersible Light 3ft still shows "Not linked to a Pancake product" in Set Assembly
-- on AO-000252 after supabase_fix_set_parts_missing_variation.sql. One result, one row per finding.
select 'package line' as section, l."PackageName" as key,
       'ItemNo=[' || coalesce(l."ItemNo", '') || '] ItemName=[' || coalesce(l."ItemName", '') || '] Qty=' || coalesce(l."Quantity"::text, '') as detail
from public."CompleteAquariumSetLine" l
where l."ItemNo" ilike '%FROK%' or l."ItemName" ilike '%FROK%'
union all
select 'items row', i."Code",
       'SKU=[' || coalesce(i."SKU", '') || '] Name=[' || coalesce(i."Name", '') || '] VariationId=[' || coalesce(i."VariationId", '') || '] Cat=' || coalesce(i."CategoryCode", '') || ' Active=' || coalesce(i."IsActive"::text, '')
from public."Items" i
where i."Code" ilike '%FROK%' or i."SKU" ilike '%FROK%' or i."Name" ilike '%FROK%'
union all
select 'variants row', v."VariationId",
       'Main=[' || coalesce(v."MainItemCode", '') || '] ItemCode=[' || coalesce(v."ItemCode", '') || '] SKU=[' || coalesce(v."SKU", '') || '] Name=[' || coalesce(v."VariantName", '') || ']'
from public."Variants" v
where v."MainItemCode" ilike '%FROK%' or v."ItemCode" ilike '%FROK%' or v."SKU" ilike '%FROK%' or v."VariantName" ilike '%FROK%'
union all
-- exactly what the Set Assembly dialog receives for each package that has the light
select 'rpc component', p."PackageName", c::text
from (select distinct l."PackageName" from public."CompleteAquariumSetLine" l
      where l."ItemNo" ilike '%FROK%' or l."ItemName" ilike '%FROK%') p
cross join lateral jsonb_array_elements(public._set_package_components(p."PackageName", 1)) c
where c::text ilike '%FROK%'
order by 1, 2;
