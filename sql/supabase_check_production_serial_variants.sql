-- Diagnostic (read-only): do production-built serials carry a variant (Black / Clear sealant SKU)?
-- Shows each production serial, the VariantCode stamped on it, and the SKU that resolves to, next to
-- the Production Order line's own VariantId. Also lists the variants that exist for each item, so
-- you can see when an item has 2+ variants (Black + Clear) but the line/serial has none picked.

select s."SerialNo", s."ItemCode", s."SourceDocumentNo",
       l."VariantId"  as prod_line_variant_id,
       s."VariantCode" as serial_variant_code,
       v."SKU"        as serial_variant_sku,
       (select string_agg(coalesce(v2."SKU", v2."VariationId"), ', ' order by v2."SKU")
          from public."Variants" v2 where v2."ItemCode" = s."ItemCode") as item_variants_available
from public."ItemSerialTracking" s
left join public."ProductionOrderOutputSerials" os on os."RunningSerialNo" = s."RunningSerialNo"
left join public."ProductionOrderOutputs" o on o."EntryNo" = os."EntryNo"
left join public."ProductionOrderLines" l on l."LineNo" = o."LineNo"
left join public."Variants" v on v."VariationId" = s."VariantCode"
where s."SourceDocumentNo" like 'PRD-%'
order by s."SourceDocumentNo", s."SerialNo";
