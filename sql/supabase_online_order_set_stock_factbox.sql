-- Stock FactBox: a SET's package parts and their serials - per "if the product is SET it will ask for
-- assemble right? can you show the Serials for the BOM for that set in the factbox".
--
-- staff_get_online_order_set_stock(order): one row per BOM part of each SET line on the order, with the
-- serials available for it at the order's branch. Same package / BOM / stock rules as the Assemble
-- dialog (staff_get_online_order_set_assembly, supabase_online_order_set_explode.sql) - but read-only
-- and from the portal's own OnlineOrderLines, NOT a Pancake re-read, so it's quick enough for the list
-- FactBox on every row click.
--   serial_tracked parts (AQ-% / production category): serials = IN_STOCK at the branch, plus any
--     RESERVED for this order (supabase_serial_order_reservation.sql) - listed first, flagged reserved.
--     Default variant picked -> that variant only; no default (staff choose in Assemble) -> any variant.
--   other parts: no serials (shown as "not serial-tracked").
-- exploded = the SET is already assembled (its "SET Material for ..." lines are on the order, and those
-- lines show in the normal Stock list).
--
-- Read-only, staff-level auth. Run AFTER supabase_online_order_set_explode.sql and
-- supabase_serial_order_reservation.sql. Safe to re-run.

drop function if exists public.staff_get_online_order_set_stock(text, text, text);

create or replace function public.staff_get_online_order_set_stock(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(set_line_id text, set_item_code text, set_description text, set_quantity numeric, package_name text, exploded boolean,
              part_no int, part_name text, part_item_code text, part_variant text, quantity numeric,
              serial_tracked boolean, requires_choice boolean, in_stock int, reserved_here int, serials jsonb)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_line record;
  v_item_code text;
  v_package text;
  v_qty numeric;
  v_display text;
  v_exploded boolean;
  v_wh text := public._online_order_warehouse_name(p_order_id);
  v_comp jsonb;
  v_no int;
  v_tracked boolean;
  v_items text[];
  v_var text;
  v_has_default boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  for v_line in
    select * from public."OnlineOrderLines"
    where "OrderID"::text = p_order_id and "LineID" not like '%~SETMAT~%'
    order by "LineID"
  loop
    v_item_code := coalesce(nullif(trim(v_line."ItemCode"), ''), nullif(trim(v_line."product_display_id"), ''));
    if upper(coalesce(public._online_order_line_category(v_line."VariationId", v_item_code), '')) <> 'SET' then
      continue;
    end if;

    v_package := public._resolve_set_package(v_line."VariationId", v_item_code);
    v_qty := coalesce(v_line."Quantity", 0);
    v_display := coalesce(nullif(trim(v_line."Description"), ''), v_item_code, v_line."VariationId", 'SET Line ' || v_line."LineID");
    v_exploded := exists (
      select 1 from public."OnlineOrderLines" m
      where m."OrderID"::text = p_order_id and trim(coalesce(m."Note", '')) = 'SET Material for ' || v_display);

    if v_package is null or v_qty <= 0 or v_qty <> trunc(v_qty) then
      -- no package mapped yet (staff pick it in Assemble) - one placeholder row
      return query select v_line."LineID"::text, v_item_code, v_display, v_qty, v_package, v_exploded,
                          0, null::text, null::text, null::text, null::numeric, false, false, 0, 0, '[]'::jsonb;
      continue;
    end if;

    v_no := 0;
    for v_comp in
      select c from jsonb_array_elements(
        public._set_components_add_stock(public._set_package_components(v_package, v_qty::int), v_wh)) c
    loop
      v_no := v_no + 1;
      v_tracked := coalesce((v_comp ->> 'serial_tracked')::boolean, false);
      v_has_default := jsonb_typeof(v_comp -> 'default') = 'object';
      v_var := case when v_has_default then nullif(trim(v_comp -> 'default' ->> 'variation_id'), '') end;
      -- the items the part can be: its default, else any of its variants (chosen in Assemble)
      if jsonb_typeof(v_comp -> 'default') = 'object' then
        v_items := array[v_comp -> 'default' ->> 'item_code'];
      else
        select coalesce(array_agg(distinct v ->> 'item_code'), array[]::text[]) into v_items
        from jsonb_array_elements(coalesce(v_comp -> 'variants', '[]'::jsonb)) v;
      end if;

      return query
        with s as (
          select st."SerialNo"::text as serial_no,
                 (st."Status" = 'RESERVED') as reserved
          from public."ItemSerialTracking" st
          where v_tracked and v_wh is not null
            and st."ItemCode" = any(v_items)
            and st."Location" = v_wh
            -- same variant match as Assemble (_set_serials_in_stock); no default = any variant
            and (not v_has_default
                 or coalesce(nullif(trim(st."VariantCode"), ''), '') = coalesce(v_var, ''))
            and (st."Status" = 'IN_STOCK'
                 or (st."Status" = 'RESERVED' and st."ReservedForOrderId" = p_order_id))
        )
        select v_line."LineID"::text, v_item_code, v_display, v_qty, v_package, v_exploded,
               v_no,
               coalesce(nullif(trim(v_comp ->> 'bom_item_name'), ''), v_comp ->> 'bom_item_no'),
               coalesce(v_comp -> 'default' ->> 'item_code', v_comp ->> 'bom_item_no'),
               nullif(trim(coalesce(v_comp -> 'default' ->> 'variant_name', '')), ''),
               (v_comp ->> 'quantity')::numeric,
               v_tracked,
               coalesce((v_comp ->> 'requires_choice')::boolean, false),
               (select count(*)::int from s where not s.reserved),
               (select count(*)::int from s where s.reserved),
               coalesce((select jsonb_agg(jsonb_build_object('serial_no', x.serial_no, 'reserved', x.reserved)
                                          order by x.reserved desc, x.serial_no)
                         from (select * from s order by s.reserved desc, s.serial_no limit 12) x), '[]'::jsonb);
    end loop;
  end loop;
end;
$$;

grant execute on function public.staff_get_online_order_set_stock(text, text, text) to anon;
