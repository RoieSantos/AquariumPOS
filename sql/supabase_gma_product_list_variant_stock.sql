-- GMA Conversations Product List: per-branch stock per variant - per "shouldnt be we can see the stocks per
-- location?" (every variant of STANDARD-75G showed "Out of stock").
--
-- The picker was matching variants against public_search_items' stock_by_variant, which only looks at stock
-- filed under the PARENT item code. A variant that has its own Items row has its stock filed under that
-- variant's own ItemCode instead (_ile_resolve_stock_key in supabase_item_ledger_entries.sql re-points it),
-- so those variants always came back 0.
--
-- public_list_item_variants now also returns stock_amaya / stock_gma, counted per variant from:
--   AQUARIUM / STAND / SUMP -> IN_STOCK ItemSerialTracking units, by Location
--   everything else         -> ItemLedgerEntries, by warehouse name (negative balances shown as 0)
-- Same stock key as the ledger (_ile_resolve_stock_key): a variant's stock is filed under its ItemCode
-- (else the parent's code), and carries a variant id ONLY when 2+ variants share that code. So a unit/entry
-- counts for the variant when its VariantCode/VariantId = the VariationId, OR - when no other variant shares
-- the code - it sits on that code with no variant id. (Rev 2: rev 1 only did the latter for variants with
-- their OWN item row, so single-variant products filed under the parent - e.g. PORPOISE-AROWANA-FOOD CAN -
-- always showed 0 · 0.)
-- Category is the variant's own item's category, else the parent's. Other columns unchanged.
-- Staff-only use (the picker) - stock is never sent to the customer.
--
-- Run AFTER supabase_chatbot_search_items_variants.sql. Safe to re-run.
-- Ends with ONE result: 'picker' rows = what the picker now shows for the 75G / arowana food can items;
-- 'ledger' rows = the arowana can's raw ledger balance per warehouse / item code / variant id, to cross-check.

drop function if exists public.public_list_item_variants(text);

create or replace function public.public_list_item_variants(p_item_code text)
returns table(variation_id text, sku text, variant_name text, price numeric, images text, quantity_in_stock int,
              stock_amaya int, stock_gma int)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with vs as (
    select v.*,
           i."Images" as item_images,
           i."QuantityInStock" as item_qty,
           upper(trim(coalesce(i."CategoryCode", p."CategoryCode", ''))) as cat,
           -- the item code this variant's stock is filed under (_ile_resolve_stock_key)
           coalesce(nullif(trim(v."ItemCode"), ''), trim(v."MainItemCode")) as stock_code,
           -- several variants share that code -> only the variant id tells them apart; otherwise the
           -- ledger stores NO variant id and everything on the code belongs to this variant
           (select count(*) from public."Variants" v2
             where v2."ItemCode" = coalesce(nullif(trim(v."ItemCode"), ''), trim(v."MainItemCode"))) >= 2 as shared
    from public."Variants" v
    left join public."Items" i on i."Code" = v."ItemCode"
    left join public."Items" p on p."Code" = v."MainItemCode"
    where v."MainItemCode" = p_item_code
  ),
  stock as (
    select vs."VariationId" as vid, b.branch,
           case when vs.cat in ('AQUARIUM', 'STAND', 'SUMP') then (
             select count(*)::int
             from public."ItemSerialTracking" s
             where upper(s."Status") = 'IN_STOCK'
               and s."Location" ilike '%' || b.branch || '%'
               and (trim(coalesce(s."VariantCode", '')) = vs."VariationId"
                    or (not vs.shared and trim(coalesce(s."VariantCode", '')) = '' and s."ItemCode" = vs.stock_code))
           )
           else coalesce((
             select greatest(round(sum(e."Quantity")), 0)::int
             from public."ItemLedgerEntries" e
             join public."Warehouses" w on w."ID" = e."WarehouseId"
             where w."Name" ilike '%' || b.branch || '%'
               and (trim(coalesce(e."VariantId", '')) = vs."VariationId"
                    or (not vs.shared and trim(coalesce(e."VariantId", '')) = '' and e."ItemCode" = vs.stock_code))
           ), 0)
           end as qty
    from vs
    cross join (values ('Amaya'), ('GMA')) as b(branch)
  )
  select
    vs."VariationId"::text,
    vs."SKU"::text,
    coalesce(nullif(trim(vs."VariantName"), ''), vs."SKU", vs."VariationId")::text,
    coalesce(vs."Price", 0)::numeric,
    coalesce(nullif(trim(vs."Images"), ''), vs.item_images)::text,
    vs.item_qty,
    coalesce((select st.qty from stock st where st.vid = vs."VariationId" and st.branch = 'Amaya'), 0),
    coalesce((select st.qty from stock st where st.vid = vs."VariationId" and st.branch = 'GMA'), 0)
  from vs
  order by vs."VariantName"
  limit 50;
$$;

grant execute on function public.public_list_item_variants(text) to anon;

notify pgrst, 'reload schema';

select * from (
  select 'picker' as section, i."Code"::text as item_code, i."Name"::text as item,
         v.variant_name || coalesce(' [' || v.sku || ']', '') as variant_or_warehouse,
         v.stock_amaya::numeric as amaya, v.stock_gma::numeric as gma, null::numeric as balance
    from public."Items" i
    cross join lateral public.public_list_item_variants(i."Code") v
   where i."IsActive" is true and (i."Name" ilike '%75G%' or i."Name" ilike '%AROWANA-FOOD%')
  union all
  select 'ledger', e."ItemCode"::text, coalesce(e."VariantId", '(no variant id)')::text,
         w."Name"::text, null, null, sum(e."Quantity")
    from public."ItemLedgerEntries" e
    join public."Warehouses" w on w."ID" = e."WarehouseId"
   where e."ItemCode" in (
           select i."Code" from public."Items" i where i."Name" ilike '%AROWANA-FOOD%'
           union
           select coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode") from public."Variants" v
            where v."MainItemCode" in (select i."Code" from public."Items" i where i."Name" ilike '%AROWANA-FOOD%'))
   group by e."ItemCode", e."VariantId", w."Name"
) r
order by section desc, item, variant_or_warehouse;
