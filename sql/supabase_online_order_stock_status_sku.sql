-- "Ready to Ship - from stock" popup: show each line's SKU (in bold, on the page) - per "can you show the
-- sku in BOLD so they will notice".
--
-- staff_get_online_order_stock_status: each entry in `lines` gains 'sku' - the variant's SKU, else the
-- item's SKU (Items."SKU"), else the Item Code (same rule as the order card's SKU column,
-- supabase_online_order_lines_sku.sql). Same body as supabase_online_order_serial_lines_dedupe.sql
-- otherwise; same signature (the new key is inside the jsonb), so create or replace is enough. The page
-- falls back to the Item Code until this is run.
-- Run AFTER supabase_online_order_serial_lines_dedupe.sql (re-running that file drops 'sku' again).

create or replace function public.staff_get_online_order_stock_status(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, warehouse_name text, has_custom_line boolean, needs_serial boolean,
              all_available boolean, lines jsonb, production_order_no text, production_order_status text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with orders as (
      select o."OrderID"::text as order_id, w."Name"::text as warehouse_name
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where o."OrderID"::text = any(coalesce(p_order_ids, '{}'))
    ),
    resolved as (
      select ord.order_id, ord.warehouse_name,
             nullif(trim(l."VariationId"), '') as variation_id,
             l."Description" as description,
             greatest(1, ceil(coalesce(l."Quantity", 1)))::int as qty,
             public._online_order_line_part(l."Description", l."ItemCode", l."product_display_id") as custom_part,
             coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), ''), nullif(trim(l."ItemCode"), '')) as item_code,
             coalesce(v."CategoryCode", i."CategoryCode") as category_code
      from orders ord
      join public."OnlineOrderLines" l on l."OrderID"::text = ord.order_id
      -- ONE row each (see header) - a join here counted the line once per match.
      left join lateral (
        select v0."ItemCode", v0."CategoryCode" from public."Variants" v0
        where nullif(trim(l."VariationId"), '') is not null and v0."VariationId" = l."VariationId"
        limit 1
      ) v on true
      left join lateral (
        select i0."Code", i0."CategoryCode" from public."Items" i0
        where i0."Code" = l."ItemCode" or i0."VariationId" = l."ItemCode"
        order by (i0."Code" = l."ItemCode") desc
        limit 1
      ) i on true
    ),
    stock_lines as (
      select r.order_id, r.warehouse_name, r.item_code, r.variation_id, min(r.description) as description, sum(r.qty)::int as needed
      from resolved r
      left join public."Categories" c on c."Code" = r.category_code
      where r.custom_part is null
        and r.item_code is not null
        and (upper(r.item_code) like 'AQ-%' or coalesce(c."IsProductionCategory", false))
      group by r.order_id, r.warehouse_name, r.item_code, r.variation_id
    ),
    counted as (
      select sl.*,
             (select count(*)::int from public."ItemSerialTracking" s
              where s."Status" = 'IN_STOCK'
                and s."ItemCode" = sl.item_code
                and coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(sl.variation_id, '')
                and s."Location" = sl.warehouse_name) as available
      from stock_lines sl
    )
    select ord.order_id,
           ord.warehouse_name,
           exists (select 1 from resolved r where r.order_id = ord.order_id and r.custom_part is not null),
           exists (select 1 from counted c where c.order_id = ord.order_id),
           coalesce(bool_and(c.available >= c.needed) filter (where c.order_id is not null), false),
           coalesce(jsonb_agg(jsonb_build_object(
             'item_code', c.item_code, 'variation_id', c.variation_id, 'description', c.description,
             'needed', c.needed, 'available', c.available,
             'variant_name', (select coalesce(nullif(trim(v."VariantName"), ''), v."SKU") from public."Variants" v where v."VariationId" = c.variation_id limit 1),
             'sku', coalesce(
               (select nullif(trim(v."SKU"), '') from public."Variants" v
                 where v."VariationId" = c.variation_id and nullif(trim(v."SKU"), '') is not null limit 1),
               (select nullif(trim(i."SKU"), '') from public."Items" i
                 where i."Code" = c.item_code and nullif(trim(i."SKU"), '') is not null limit 1),
               c.item_code)
           ) order by c.item_code) filter (where c.order_id is not null), '[]'::jsonb),
           (select po."No"::text from public."ProductionOrders" po
             where po."SourceOnlineOrderId" = ord.order_id
             order by (po."Status" <> 'Finished') desc, po."CreatedAtUtc" desc limit 1),
           (select po."Status"::text from public."ProductionOrders" po
             where po."SourceOnlineOrderId" = ord.order_id
             order by (po."Status" <> 'Finished') desc, po."CreatedAtUtc" desc limit 1)
    from orders ord
    left join counted c on c.order_id = ord.order_id
    group by ord.order_id, ord.warehouse_name;
end;
$$;
grant execute on function public.staff_get_online_order_stock_status(text, text, text[]) to anon;
