-- Fix: Ready to Ship's "Select Serials to Ship" showed the same order line twice (order 105852: one
-- STANDARD-10G line x2 asked for "need 2" twice = 4 serials).
--
-- UPDATE: the check at the bottom showed Items has only one AQ-030 row - 105852 really has two stale
-- OnlineOrderLines rows. The actual fix is supabase_online_order_lines_block_pos_resurrect.sql. This
-- file's one-Items-row-per-line change is still a safe guard and can stay.
--
-- Cause: both functions below find a line's item with
--   left join "Items" i on i."Code" = l."ItemCode" or i."VariationId" = l."ItemCode"
-- which returns the line once per matching Items row - so a line whose code matches 2 Items rows
-- (a duplicate item, or one row by Code and another by VariationId) came back twice. The Lines grid
-- reads OnlineOrderLines directly, so it still showed 1 line.
--   - admin_get_online_order_serial_requirements (supabase_online_order_to_ship_serials.sql): the
--     serial picker listed the line twice.
--   - staff_get_online_order_stock_status (supabase_online_order_stock_ship.sql): SUMS the rows, so it
--     counted 4 needed - "Ready to Ship" vs "Assign - build missing units" was judged on the doubled
--     number, and a build would have been for too many units.
-- Now each line takes ONE Items row (Code match first, then VariationId match) and ONE Variants row.
-- Same columns/signatures, so nothing on the page changes. The check at the bottom lists the item
-- codes that match more than one Items row (read-only).
--
-- Safe to re-run. Functions only.

-- ---------------------------------------------------------------------------
create or replace function public.admin_get_online_order_serial_requirements(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(
  line_id text,
  item_code text,
  variation_id text,
  description text,
  quantity_needed int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with resolved as (
      select
        l."LineID" as line_id,
        nullif(trim(l."VariationId"), '') as variation_id,
        l."Description" as description,
        l."Quantity" as quantity,
        coalesce(
          nullif(trim(v."ItemCode"), ''),
          nullif(trim(i."Code"), ''),
          nullif(trim(l."ItemCode"), '')
        ) as resolved_item_code,
        coalesce(v."CategoryCode", i."CategoryCode") as resolved_category_code
      from public."OnlineOrderLines" l
      -- ONE row each (see header) - a join here returned the line once per match.
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
      where l."OrderID" = p_order_id
    )
    select
      r.line_id::text,
      r.resolved_item_code::text,
      r.variation_id::text,
      coalesce(nullif(trim(r.description), ''), r.resolved_item_code)::text,
      greatest(1, ceil(coalesce(r.quantity, 1)))::int
    from resolved r
    left join public."Categories" c on c."Code" = r.resolved_category_code
    where r.resolved_item_code is not null
      and (
        upper(r.resolved_item_code) like 'AQ-%'
        or upper(r.resolved_item_code) like 'CUSTOM-AQUARIUM%'
        or upper(r.resolved_item_code) like 'CUSTOM_STAND%'
        or upper(r.resolved_item_code) like 'CUSTOM-SUMP%'
        or upper(r.resolved_item_code) like 'CUSTOM_SUMP%'
        or coalesce(c."IsProductionCategory", false)
      );
end;
$$;
grant execute on function public.admin_get_online_order_serial_requirements(text, text, text) to anon;

-- ---------------------------------------------------------------------------
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
             'variant_name', (select coalesce(nullif(trim(v."VariantName"), ''), v."SKU") from public."Variants" v where v."VariationId" = c.variation_id limit 1)
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

-- ---------------------------------------------------------------------------
-- Read-only check: which item codes on order 105852 match more than one Items row (the cause).
select l."LineID", l."ItemCode", l."Quantity", i."Code" as items_code, i."VariationId" as items_variation_id
from public."OnlineOrderLines" l
join public."Items" i on i."Code" = l."ItemCode" or i."VariationId" = l."ItemCode"
where l."OrderID" = '105852'
order by l."LineID";
