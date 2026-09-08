-- DIAGNOSTIC ONLY - reads, never writes. Run this BEFORE changing how a Purchase Order receipt
-- picks its Pancake variation, to answer "are we certain the variant will be updated in Pancake?"
-- with this shop's own live data rather than with reasoning about the code.
--
-- BACKGROUND. staff_receive_purchase_order_lines (supabase_purchase_order_pancake_sync.sql) builds
-- its POST /purchases payload with:
--
--   select "VariationId" into v_variation_id from public."Items" where "Code" = v_po_line."ItemCode";
--
-- Items holds one row per Pancake PRODUCT, and its "VariationId" is a single REPRESENTATIVE
-- variation written by the sync's cross-link step (distinct on (item_code) ... order by
-- variation_id desc, see supabase_pancake_item_sku_match_fix.sql). So every line of a product
-- receives against that one variation, whichever variant the line actually names. The proposed fix
-- sends the line's own "VariantCode" instead - which IS a Pancake VariationId, sourced from the
-- same /products/variations feed that populated Items."VariationId" in the first place.
--
-- These five queries test that proposal against real data. Run them in order.

-- ============================================================================
-- 1. Is the stock cache usable? Everything below leans on it.
--
-- ItemWarehouseStockCache is filled from Pancake's own per-warehouse stock endpoint
-- (supabase_item_warehouse_stock.sql), so every VariationId in it is an id PANCAKE ITSELF
-- returned. That is what makes it usable as proof rather than as an assumption.
--
-- If cached_rows is 0 or last_refresh is old, refresh it from the Stock On Hand page first -
-- queries 2 and 4 prove nothing against an empty cache.
select
  count(*) as cached_rows,
  count(distinct "VariationId") as distinct_variations,
  count(distinct "ItemCode") as distinct_items,
  max("FetchedAtUtc") as last_refresh
from public."ItemWarehouseStockCache";

-- ============================================================================
-- 2. Does Pancake track stock PER VARIATION, or roll it up to the product?
--
-- THE CENTRAL QUESTION. Rows here are one product's several variations, each with its own
-- RemainQuantity per warehouse. Different quantities against different VariationIds for the same
-- ItemCode = Pancake holds stock at variation level, and a receipt aimed at the wrong variation
-- lands in the wrong place. Identical quantities everywhere would mean the opposite - that the
-- variant makes no difference to stock at all, and the fix is pointless.
select
  c."ItemCode",
  c."VariationId",
  v."SKU",
  v."VariantName",
  c."WarehouseId",
  c."RemainQuantity"
from public."ItemWarehouseStockCache" c
left join public."Variants" v on v."VariationId" = c."VariationId"
where c."ItemCode" in (
  select "ItemCode"
  from public."ItemWarehouseStockCache"
  group by "ItemCode"
  having count(distinct "VariationId") > 1
)
order by c."ItemCode", c."WarehouseId", c."VariationId"
limit 200;

-- ============================================================================
-- 3. Blast radius: how many variants currently collapse onto one variation id?
--
-- variant_count is how many variants of that product exist; sent_today is the single variation
-- every receipt of any of them currently goes to. representative_is_a_real_variant should be true -
-- if it is false, the item's stamped VariationId does not even correspond to one of its own
-- variants, which is its own problem worth knowing about.
select
  i."Code",
  i."Name",
  i."VariationId" as sent_today,
  count(v."VariationId") as variant_count,
  bool_or(v."VariationId" = i."VariationId") as representative_is_a_real_variant
from public."Items" i
join public."Variants" v on coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode") = i."Code"
group by i."Code", i."Name", i."VariationId"
having count(v."VariationId") > 1
order by count(v."VariationId") desc, i."Code"
limit 100;

-- ============================================================================
-- 4. Would the id the fix sends actually be accepted?
--
-- One row per open PO line that names a variant. Read the last two columns:
--   variant_row_exists  - the VariantCode resolves to a Variants row (it came from the picker,
--                         so this should always be true).
--   known_to_pancake    - Pancake's own stock endpoint has returned this exact variation id.
--                         TRUE is the strongest evidence available without calling POST /purchases:
--                         the id is real, live, and in the same id space the working call already
--                         uses. FALSE means either the cache is stale/empty (see query 1) or that
--                         variation carries no stock row anywhere - worth checking by hand before
--                         receiving against it.
-- would_change tells you which lines the fix actually redirects.
select
  l."PONo",
  l."EntryNo",
  l."ItemCode",
  l."VariantCode",
  l."VariantName",
  (select i."VariationId" from public."Items" i where i."Code" = l."ItemCode" limit 1) as sent_today,
  l."VariantCode" <> coalesce((select i."VariationId" from public."Items" i where i."Code" = l."ItemCode" limit 1), '') as would_change,
  exists (select 1 from public."Variants" v where v."VariationId" = l."VariantCode") as variant_row_exists,
  exists (select 1 from public."ItemWarehouseStockCache" c where c."VariationId" = l."VariantCode") as known_to_pancake
from public."PurchaseOrderLines" l
where l."VariantCode" is not null
order by l."PONo", l."EntryNo";

-- ============================================================================
-- 5. What has actually been sent to Pancake so far?
--
-- The real payloads, straight out of the receipt log. Every variation_id_sent here went to Pancake
-- and came back 'Synced', so this doubles as the proof that a variation id in this field is
-- accepted - the fix changes WHICH id goes in that field, not the field or its format.
--
-- Where several rows of one PO share a variation_id_sent, that is this problem in the wild.
select
  p."PONo",
  p."ReceivedAtUtc",
  p."Sync Status",
  p."Pancake Purchase ID",
  x.value ->> 'variation_id' as variation_id_sent,
  (x.value ->> 'quantity')::numeric as quantity_sent,
  v."SKU" as variation_sku,
  v."VariantName" as variation_name
from public."PurchaseOrder_Pancake_Purchases" p
cross join lateral jsonb_array_elements(p."Items Json") x
left join public."Variants" v on v."VariationId" = x.value ->> 'variation_id'
order by p."ReceivedAtUtc" desc, p."PONo"
limit 100;
