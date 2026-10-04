-- Stock check for SET orders - per "can we check the items if its has stocks for production items
-- Aquarium / Tank and Sump" (order 109310: a SET-only order showed no Ready to Ship, because the SET line
-- itself is not a production item, so the stock check found nothing to count).
--
-- staff_get_online_order_stock_status now also looks INSIDE each SET line that hasn't been exploded yet:
-- the SET's BOM package (supabase_online_order_set_explode.sql) gives its parts - the default variant the
-- SET dialog would pre-select, quantity = BOM qty x SET qty - and the production ones (AQ-% codes or a
-- production category: aquarium / tank, sump, ...) are counted against In Stock serials at the order's
-- branch, exactly like a normal stock line. So a SET order gets the same buttons as a stock tank order:
--   every part in stock     -> Ready to Ship (SET dialog, then serials)
--   some part short         -> Assign: builds the missing parts on a Production Order
-- Once the SET is exploded (its "SET Material for ..." lines exist) the parts are real order lines and are
-- counted the normal way instead.
--
-- New columns (so the function is dropped and re-created):
--   has_set_line  - the order has a SET line
--   set_unmapped  - a SET line has no package yet (stock can't be checked; staff pick it in the SET dialog)
--   set_pending   - a SET line isn't assembled yet (no "SET Material for ..." lines) - the page shows
--                   the Assemble button; once assembled the parts are counted as normal order lines
-- Each `lines` entry also gains 'from_set' and 'choose_variant' (the package line has several variants
-- and none matches its Item No - counted across all variants; can't be built until the BOM line is set
-- to the exact variant).
--
-- Sealant (per "if its set.. checking on stocks you can check either clear or black sealant, upon ready
-- to ship they will choose before shipping"): a SET part whose variants are Black / Clear sealant
-- (sealant_choice from _set_package_components - same name/SKU rule as the Sealant Sales report) is
-- counted across BOTH colours of that product ('sealant_any', variant_name "Black or Clear sealant").
-- The colour is picked in the SET dialog at Ready to Ship; if the part is short, the Assign build dialog
-- asks which colour to build ('sealant_options').
--
-- The SET line ITSELF is never stock-checked or serial-picked (per "SET products dont need to check the
-- SET STOCK.. it should check the package items stocks") - excluded by category, even if the SET
-- category is flagged as a production category or its code starts with AQ-. Also applied to
-- admin_get_online_order_serial_requirements (bottom of this file).
--
-- Same body as supabase_online_order_stock_status_sku.sql otherwise.
-- Run AFTER supabase_online_order_stock_status_sku.sql and supabase_online_order_set_explode.sql.
-- Safe to re-run. (Re-running stock_status_sku.sql afterwards would fail on the changed return type -
-- don't; this file supersedes it.)

drop function if exists public.staff_get_online_order_stock_status(text, text, text[]);

create or replace function public.staff_get_online_order_stock_status(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, warehouse_name text, has_custom_line boolean, needs_serial boolean,
              all_available boolean, lines jsonb, production_order_no text, production_order_status text,
              has_set_line boolean, set_unmapped boolean, set_pending boolean)
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
             coalesce(v."CategoryCode", i."CategoryCode") as category_code,
             false as from_set,
             false as choose_variant,
             null::text as main_code,
             false as sealant_any
      from orders ord
      join public."OnlineOrderLines" l on l."OrderID"::text = ord.order_id
      -- ONE row each - a join here counted the line once per match.
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
      -- The SET line itself is never stock-checked - only its package's parts (set_parts below).
      where upper(public._online_order_line_category(l."VariationId",
              coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), '')))) <> 'SET'
    ),
    -- SET lines and their package (null = not mapped yet). exploded = its materials are already lines.
    set_lines as (
      select ord.order_id, ord.warehouse_name,
             public._resolve_set_package(l."VariationId", coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), ''))) as package_name,
             greatest(1, ceil(coalesce(l."Quantity", 1)))::int as set_qty,
             exists (
               select 1 from public."OnlineOrderLines" m
               where m."OrderID" = l."OrderID"
                 and trim(coalesce(m."Note", '')) = 'SET Material for ' || coalesce(
                   nullif(trim(l."Description"), ''), nullif(trim(l."ItemCode"), ''), nullif(trim(l."VariationId"), ''), 'SET Line ' || l."LineID")
             ) as exploded
      from orders ord
      join public."OnlineOrderLines" l on l."OrderID"::text = ord.order_id
      where l."LineID" not like '%~SETMAT~%'
        and upper(public._online_order_line_category(l."VariationId",
              coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), '')))) = 'SET'
    ),
    -- Parts of the not-yet-exploded SET lines, as the SET dialog would default them.
    set_parts as (
      select p.order_id, p.warehouse_name, p.variation_id, p.description, p.qty,
             null::text as custom_part, p.item_code,
             nullif(public._online_order_line_category(coalesce(p.variation_id, p.category_variation_id), p.item_code), '') as category_code,
             true as from_set, p.choose_variant, p.main_code, p.sealant_any
      from (
        select sl.order_id, sl.warehouse_name,
               -- Sealant part: no colour yet (picked at Ready to Ship) - counted across Black + Clear.
               case when sealant then null else nullif(comp -> 'default' ->> 'variation_id', '') end as variation_id,
               case when sealant then comp ->> 'bom_item_name'
                    else coalesce(comp -> 'default' ->> 'name', comp ->> 'bom_item_name') end as description,
               (comp ->> 'quantity')::numeric::int as qty,
               case when sealant then coalesce(nullif(comp -> 'variants' -> 0 ->> 'item_code', ''), comp ->> 'main_item_code', comp ->> 'bom_item_no')
                    else coalesce(nullif(comp -> 'default' ->> 'item_code', ''), comp ->> 'bom_item_no') end as item_code,
               nullif(comp -> 'variants' -> 0 ->> 'variation_id', '') as category_variation_id,
               not sealant and jsonb_typeof(comp -> 'default') is distinct from 'object' as choose_variant,
               coalesce(comp ->> 'main_item_code', comp ->> 'bom_item_no') as main_code,
               sealant as sealant_any
        from set_lines sl
        cross join lateral jsonb_array_elements(public._set_package_components(sl.package_name, sl.set_qty)) comp
        cross join lateral (select coalesce((comp ->> 'sealant_choice')::boolean, false) as sealant) sc
        where sl.package_name is not null and not sl.exploded
      ) p
      where p.qty > 0
    ),
    -- Black / Clear sealant variants per main product (same rule as the Sealant Sales report).
    sealant_variants as (
      select v."VariationId" as variation_id,
             coalesce(nullif(trim(v."MainItemCode"), ''), v."ItemCode") as main_code,
             coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode") as item_code,
             v."SKU" as sku,
             case when (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* 'black' then 'Black' else 'Clear' end as colour
      from public."Variants" v
      where (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* 'sealant'
        and (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* '(black|clear)'
    ),
    all_lines as (
      select * from resolved
      union all
      select * from set_parts
    ),
    stock_lines as (
      select r.order_id, r.warehouse_name, r.item_code, r.variation_id, r.main_code, r.sealant_any,
             min(r.description) as description,
             sum(r.qty)::int as needed, bool_or(r.from_set) as from_set, bool_or(r.choose_variant) as choose_variant
      from all_lines r
      left join public."Categories" c on c."Code" = r.category_code
      where r.custom_part is null
        and r.item_code is not null
        and (upper(r.item_code) like 'AQ-%' or coalesce(c."IsProductionCategory", false))
      group by r.order_id, r.warehouse_name, r.item_code, r.variation_id, r.main_code, r.sealant_any
    ),
    counted as (
      select sl.*,
             (select count(*)::int from public."ItemSerialTracking" s
              where s."Status" = 'IN_STOCK'
                and s."Location" = sl.warehouse_name
                and case
                  -- SET sealant part: a unit of either colour of this product counts.
                  when sl.sealant_any then exists (
                    select 1 from sealant_variants sv
                    where sv.main_code = sl.main_code and sv.variation_id = nullif(trim(s."VariantCode"), ''))
                  -- No default variant picked yet - any variant of the item counts.
                  when sl.choose_variant then s."ItemCode" = sl.item_code
                  else s."ItemCode" = sl.item_code
                       and coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(sl.variation_id, '')
                end) as available
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
             'from_set', c.from_set, 'choose_variant', c.choose_variant,
             'sealant_any', c.sealant_any,
             -- Colours to pick from when a short sealant part is built (Assign).
             'sealant_options', case when c.sealant_any then (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'variation_id', sv.variation_id, 'item_code', sv.item_code, 'sku', sv.sku, 'colour', sv.colour)
                      order by sv.colour), '[]'::jsonb)
               from sealant_variants sv where sv.main_code = c.main_code) end,
             'variant_name', case when c.sealant_any then 'Black or Clear sealant' else
               (select coalesce(nullif(trim(v."VariantName"), ''), v."SKU") from public."Variants" v where v."VariationId" = c.variation_id limit 1) end,
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
             order by (po."Status" <> 'Finished') desc, po."CreatedAtUtc" desc limit 1),
           exists (select 1 from set_lines sl where sl.order_id = ord.order_id),
           exists (select 1 from set_lines sl where sl.order_id = ord.order_id and sl.package_name is null and not sl.exploded),
           exists (select 1 from set_lines sl where sl.order_id = ord.order_id and not sl.exploded)
    from orders ord
    left join counted c on c.order_id = ord.order_id
    group by ord.order_id, ord.warehouse_name;
end;
$$;

grant execute on function public.staff_get_online_order_stock_status(text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- Serial picker at Ready to Ship: never ask a serial for the SET line itself - its serial-tracked parts
-- (aquarium, sump, ...) are their own order lines once assembled. Same body as
-- supabase_online_order_serial_lines_dedupe.sql plus the SET exclusion; same signature.
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
      -- ONE row each - a join here returned the line once per match.
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
        and upper(public._online_order_line_category(l."VariationId",
              coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), '')))) <> 'SET'
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
