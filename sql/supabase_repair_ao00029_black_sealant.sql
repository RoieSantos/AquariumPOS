-- One-off repair: AO-00029 (Benjamin Inta, Pancake order 106916) - the AI bot placed 6x BETTA-CUBE (AQ-024)
-- with "Black Sealant" only in the line note, so the line had no VariationId and the Pancake push fell
-- back to the product's default variation (AQ-024-ClearSealant). This tags the portal line to the Black
-- Sealant variant (AQ-024-BlackSealant, VariationId 72ff7550-cd94-45cc-ba0a-52dd1e74484a).
--
-- This only fixes the PORTAL copy (Automated Orders page / invoice). It does NOT change the order already
-- in Pancake - edit order 106916 in Pancake by hand to swap the variant to AQ-024-BlackSealant.
-- Safe to re-run. Ends with one result row showing the line after the update.

update public."AutomatedOrderLines" l
set "VariationId" = '72ff7550-cd94-45cc-ba0a-52dd1e74484a'
where l."OrderNo" = 'AO-00029'
  and l."ItemCode" = 'AQ-024'
  and exists (select 1 from public."Variants" v
              where v."VariationId" = '72ff7550-cd94-45cc-ba0a-52dd1e74484a' and v."SKU" = 'AQ-024-BlackSealant');

select l."OrderNo", l."ItemCode", l."ItemName", l."Quantity", l."VariationId", v."SKU" as variant_sku, l."Notes"
from public."AutomatedOrderLines" l
left join public."Variants" v on v."VariationId" = l."VariationId"
where l."OrderNo" = 'AO-00029';
