-- Read-only check for the portal's SET explosion (supabase_online_order_set_explode.sql - run that first):
--   1. Every package in the Supabase copy (Customer Aquarium page) and how many BOM lines it has.
--      The POS reads its LOCAL dbo.CompleteAquariumSet* tables - packages that exist only there are
--      missing here and must be re-created on the Customer Aquarium page.
--   2. SET-category products (Variants) that no package resolves to yet - staff will be asked to pick
--      the package the first time one is shipped from the portal.
--   3. BOM lines whose item is not linked to a Pancake product (no VariationId) - the portal refuses
--      to explode those (untick them in the dialog or fix the item).

select section, name, detail, value
from (
  select 1 as sort, 'package' as section, h."PackageName"::text as name,
         coalesce(nullif(h."VariantID", ''), '(no VariantID)')::text as detail,
         count(l."EntryNo")::text || ' BOM line(s)' as value
  from public."CompleteAquariumSetHeader" h
  left join public."CompleteAquariumSetLine" l
    on l."PackageName" = h."PackageName" and trim(coalesce(l."ItemNo", '')) <> ''
  group by h."PackageName", h."VariantID"

  union all

  select 2, 'SET product with no package yet', v."VariationId"::text,
         coalesce(v."VariantName", v."ItemCode", v."MainItemCode")::text, 'will ask on first ship'
  from public."Variants" v
  where upper(trim(coalesce(v."CategoryCode", ''))) = 'SET'
    and public._resolve_set_package(v."VariationId", coalesce(nullif(v."ItemCode", ''), v."MainItemCode")) is null

  union all

  select 3, 'BOM line not linked to Pancake', l."PackageName"::text,
         (l."ItemNo" || ' - ' || coalesce(l."ItemName", ''))::text, 'no VariationId in Items / Variants'
  from public."CompleteAquariumSetLine" l
  where trim(coalesce(l."ItemNo", '')) <> ''
    and not exists (select 1 from public."Items" i where i."Code" = trim(l."ItemNo") and nullif(trim(i."VariationId"), '') is not null)
    and not exists (select 1 from public."Variants" v where v."MainItemCode" = trim(l."ItemNo") or v."ItemCode" = trim(l."ItemNo"))
) x
order by sort, name, detail;
