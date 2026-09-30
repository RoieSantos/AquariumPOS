-- Alice: clean variant option (color) in stock_by_variant - per "it is not showing per variant / sku or color
-- mostly it will show black sealant or clear sealant, for stand its black paint or white paint".
--
-- stock_by_variant's "variant" label (supabase_chatbot_stock_by_variant.sql) was the serial's ItemDescription
-- snapshot, e.g. "AQ-021-BlackSealant | Standard 35G Aquarium – 30×16×18in, 6mm glass ... | STANDARD-35G (...)",
-- so the actual option was buried and Alice summarised it away. Each element now leads with "option": the
-- variant SKU minus the item-code prefix, CamelCase split into words ("AQ-021-BlackSealant" -> "Black Sealant",
-- "AST-011-WhitePaint" -> "White Paint"). Falls back to the old label when the variant has no SKU.
-- Elements are now {option, sku, Amaya, GMA} (variant_id / long label dropped - Alice never needs them).
--
-- Only _chatbot_item_stock_by_variant changes (same signature), so public_search_items /
-- public_list_order_items pick it up without being re-created.
--
-- Run AFTER supabase_chatbot_stock_by_variant.sql. Safe to re-run.

create or replace function public._chatbot_item_stock_by_variant(p_item_code text, p_category_code text)
returns jsonb
language sql
security definer
set search_path = public, extensions
stable
as $$
  with src as (
    select nullif(trim(s."VariantCode"), '') as vc,
           nullif(trim(s."ItemDescription"), '') as descr,
           case when s."Location" ilike '%Amaya%' then 'Amaya' when s."Location" ilike '%GMA%' then 'GMA' end as branch,
           1::numeric as qty
    from public."ItemSerialTracking" s
    where upper(trim(coalesce(p_category_code, ''))) in ('AQUARIUM', 'STAND', 'SUMP')
      and s."ItemCode" = p_item_code
      and upper(s."Status") = 'IN_STOCK'
    union all
    select nullif(trim(e."VariantId"), ''),
           null::text,
           case when w."Name" ilike '%Amaya%' then 'Amaya' when w."Name" ilike '%GMA%' then 'GMA' end,
           e."Quantity"
    from public."ItemLedgerEntries" e
    join public."Warehouses" w on w."ID" = e."WarehouseId"
    where upper(trim(coalesce(p_category_code, ''))) not in ('AQUARIUM', 'STAND', 'SUMP')
      and e."ItemCode" = p_item_code
  ),
  per_variant as (
    select vc,
           max(descr) as descr,
           greatest(coalesce(sum(qty) filter (where branch = 'Amaya'), 0), 0)::int as amaya,
           greatest(coalesce(sum(qty) filter (where branch = 'GMA'), 0), 0)::int as gma
    from src
    group by vc
  ),
  labelled as (
    select pv.vc, nullif(trim(v."SKU"), '') as sku, pv.amaya, pv.gma,
           coalesce(pv.descr, nullif(trim(v."VariantName"), ''), case when pv.vc is null then '(no variant)' else pv.vc end) as label
    from per_variant pv
    left join public."Variants" v on v."VariationId" = pv.vc
    where pv.amaya > 0 or pv.gma > 0
  ),
  optioned as (
    select l.*,
           coalesce(
             nullif(trim(regexp_replace(
               case when upper(l.sku) like upper(p_item_code) || '-%' then substr(l.sku, length(p_item_code) + 2) else l.sku end,
               '([a-z])([A-Z])', '\1 \2', 'g')), ''),
             l.label
           ) as opt
    from labelled l
  )
  select case
    when not exists (select 1 from optioned where vc is not null) then null
    else (
      select jsonb_agg(jsonb_build_object('option', o.opt, 'sku', o.sku, 'Amaya', o.amaya, 'GMA', o.gma)
                       order by o.opt)
      from optioned o
    )
  end;
$$;

revoke all on function public._chatbot_item_stock_by_variant(text, text) from public, anon, authenticated;

notify pgrst, 'reload schema';
