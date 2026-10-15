-- Stock FactBox: SKU + item description on every line - per "can you add a sku and item description to the
-- factbox for better reading".
--
-- The FactBox showed the item code and the order line's own text (or, for SET parts, the BOM's name, which
-- is often just the SKU again). Now each line also gets:
--   staff_get_lines_stock_by_warehouse / staff_get_document_stock_by_warehouse: sku (the variant's SKU,
--     else the item's) and item_name (Items.Name, else Description; with the variant's name when the line
--     is one variant).
--   staff_get_online_order_set_stock: part_sku and part_description (the default variant's SKU /
--     description from the package, else the BOM item's).
-- docs/js/itemStockFactbox.js shows "SKU" next to the code and the item description under it.
--
-- Same bodies as supabase_serial_order_reservation.sql (lines / document) and
-- supabase_online_order_set_stock_factbox.sql (SET parts) plus those columns - don't re-run those older
-- files' versions afterwards. Read-only functions, safe to re-run. Run AFTER both files.

drop function if exists public.staff_get_document_stock_by_warehouse(text, text, text, text);
drop function if exists public.staff_get_lines_stock_by_warehouse(text, text, jsonb);

create or replace function public.staff_get_lines_stock_by_warehouse(
  p_admin_username text,
  p_admin_password text,
  p_lines jsonb
)
returns table(line_key text, item_code text, variant_id text, source text,
              warehouse_id text, warehouse_name text, is_stock_warehouse boolean, quantity numeric,
              reserved numeric, sku text, item_name text)
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
    with input as (
      select x->>'key' as k,
             nullif(trim(x->>'item_code'), '') as raw_item,
             nullif(trim(x->>'variant_id'), '') as var
      from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x
    ),
    resolved as (
      select inp.k, inp.var,
             coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), '')) as item,
             nullif(trim(v."MainItemCode"), '') as main_item
      from input inp
      left join lateral (
        select v0."ItemCode", v0."MainItemCode" from public."Variants" v0
        where inp.var is not null and v0."VariationId" = inp.var
        limit 1
      ) v on true
      left join lateral (
        select i0."Code" from public."Items" i0
        where inp.raw_item is not null and (i0."Code" = inp.raw_item or i0."VariationId" = inp.raw_item)
        order by (i0."Code" = inp.raw_item) desc
        limit 1
      ) i on true
    ),
    lines as (
      select r.k, r.var, r.item,
             upper(trim(coalesce(ic."CategoryCode", mc."CategoryCode", ''))) in ('AQUARIUM', 'STAND', 'SUMP') as by_serial,
             -- supabase_stock_factbox_sku_name.sql: the variant's SKU, else the item's; item name (+ variant)
             coalesce(nullif(trim(vv."SKU"), ''), nullif(trim(ic."SKU"), ''), nullif(trim(mc."SKU"), '')) as sku,
             nullif(concat_ws(' · ',
               coalesce(nullif(trim(ic."Name"), ''), nullif(trim(ic."Description"), ''),
                        nullif(trim(mc."Name"), ''), nullif(trim(mc."Description"), '')),
               nullif(trim(vv."VariantName"), '')), '') as item_name
      from resolved r
      left join public."Items" ic on ic."Code" = r.item
      left join public."Items" mc on mc."Code" = r.main_item
      left join lateral (
        select v0."SKU", v0."VariantName" from public."Variants" v0
        where r.var is not null and v0."VariationId" = r.var limit 1
      ) vv on true
      where r.item is not null
    ),
    -- every item code a line covers: the item itself, plus (no variant picked) its variants' own codes
    line_codes as (
      select l.k, l.item as code from lines l
      union
      select l.k, v."ItemCode" from lines l
      join public."Variants" v on v."MainItemCode" = l.item
      where l.var is null and nullif(trim(v."ItemCode"), '') is not null
    ),
    ledger as (
      select l.k, e."WarehouseId"::text as wid, sum(e."Quantity") as qty, 0::numeric as res
      from lines l
      join line_codes lc on lc.k = l.k
      join public."ItemLedgerEntries" e on e."ItemCode" = lc.code
      where not l.by_serial
        -- a variant is booked either under its own ItemCode (VariantId empty) or under the shared
        -- item with VariantId set (items with 2+ variants, _ile_resolve_stock_key)
        and (l.var is null or coalesce(e."VariantId", '') in ('', l.var))
      group by l.k, e."WarehouseId"
    ),
    serials as (
      select l.k, w."ID"::text as wid,
             count(*) filter (where s."Status" = 'IN_STOCK')::numeric as qty,
             count(*) filter (where s."Status" = 'RESERVED')::numeric as res
      from lines l
      join line_codes lc on lc.k = l.k
      join public."ItemSerialTracking" s
        on s."ItemCode" = lc.code and s."Status" in ('IN_STOCK', 'RESERVED')
       and (l.var is null or coalesce(nullif(trim(s."VariantCode"), ''), '') in ('', l.var))
      join public."Warehouses" w on lower(trim(w."Name")) = lower(trim(s."Location"))
      where l.by_serial
      group by l.k, w."ID"
    ),
    balances as (
      select * from ledger
      union all
      select * from serials
    )
    select l.k, l.item, l.var,
           case when l.by_serial then 'serials' else 'ledger' end,
           w."ID"::text, coalesce(w."Name", w."ID")::text,
           coalesce(w."IsActive", true) and coalesce(w."IsStockWarehouse", false),
           coalesce(b.qty, 0)::numeric,
           coalesce(b.res, 0)::numeric,
           l.sku::text, l.item_name::text
    from lines l
    cross join public."Warehouses" w
    left join balances b on b.k = l.k and b.wid = w."ID"::text
    where (coalesce(w."IsActive", true) and coalesce(w."IsStockWarehouse", false))
       or coalesce(b.qty, 0) <> 0 or coalesce(b.res, 0) <> 0
    order by l.k, w."Name";
end;
$$;

grant execute on function public.staff_get_lines_stock_by_warehouse(text, text, jsonb) to anon;

-- supabase_document_stock_by_warehouse.sql's version plus the reserved column.
create or replace function public.staff_get_document_stock_by_warehouse(
  p_admin_username text,
  p_admin_password text,
  p_doc_type text,
  p_doc_no text
)
returns table(line_key text, item_code text, variant_id text, label text, doc_warehouse text, source text,
              warehouse_id text, warehouse_name text, is_stock_warehouse boolean, quantity numeric,
              reserved numeric, sku text, item_name text)
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
    with src as (
      select coalesce(nullif(trim(l."ItemCode"::text), ''), nullif(trim(l."product_display_id"::text), '')) as item,
             nullif(trim(l."VariationId"::text), '') as var,
             l."Description"::text as lbl,
             o."LocationID"::text as wh
      from public."OnlineOrderLines" l
      left join public."OnlineOrders" o on o."OrderID"::text = l."OrderID"::text
      where p_doc_type = 'online' and l."OrderID"::text = p_doc_no
      union all
      select l."No"::text, null::text, l."Description"::text, a."Warehouse"::text
      from public."AdvanceOrderLines" l
      left join public."AdvanceOrders" a on a."TransactionNo" = l."TransactionNo"
      where p_doc_type = 'advance' and l."TransactionNo" = p_doc_no
      union all
      select l."Item No."::text, nullif(trim(coalesce(l."Variant ID", '')), ''),
             coalesce(nullif(trim(l."Description"), ''), l."Variant Name")::text, h."From Warehouse ID"::text
      from public."Transfer_Line" l
      left join public."Transfer_Header" h on h."No." = l."Document No."
      where p_doc_type = 'transfer' and l."Document No." = p_doc_no
      union all
      select l."ItemCode"::text, nullif(trim(coalesce(l."VariantCode", '')), ''),
             coalesce(nullif(trim(l."Description"), ''), l."ItemName")::text, l."WarehouseId"::text
      from public."PurchaseOrderLines" l
      where p_doc_type = 'purchase' and l."PONo" = p_doc_no
    ),
    -- one entry per item + variant + warehouse (the same item on two lines is shown once)
    keyed as (
      select (row_number() over (order by min(s.lbl)))::text as k, s.item, s.var, min(s.lbl) as lbl, s.wh
      from src s
      where s.item is not null
      group by s.item, s.var, s.wh
    )
    select k.k, st.item_code, st.variant_id, k.lbl, k.wh, st.source,
           st.warehouse_id, st.warehouse_name, st.is_stock_warehouse, st.quantity, st.reserved,
           st.sku, st.item_name
    from keyed k
    join public.staff_get_lines_stock_by_warehouse(
           p_admin_username, p_admin_password,
           (select coalesce(jsonb_agg(jsonb_build_object('key', k2.k, 'item_code', k2.item, 'variant_id', k2.var)), '[]'::jsonb)
            from keyed k2)
         ) st on st.line_key = k.k
    order by k.k::int, st.warehouse_name;
end;
$$;

grant execute on function public.staff_get_document_stock_by_warehouse(text, text, text, text) to anon;

drop function if exists public.staff_get_online_order_set_stock(text, text, text);

create or replace function public.staff_get_online_order_set_stock(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(set_line_id text, set_item_code text, set_description text, set_quantity numeric, package_name text, exploded boolean,
              part_no int, part_name text, part_item_code text, part_variant text, quantity numeric,
              serial_tracked boolean, requires_choice boolean, in_stock int, reserved_here int, serials jsonb,
              part_sku text, part_description text)
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
                          0, null::text, null::text, null::text, null::numeric, false, false, 0, 0, '[]'::jsonb,
                          null::text, null::text;
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
                         from (select * from s order by s.reserved desc, s.serial_no limit 12) x), '[]'::jsonb),
               -- supabase_stock_factbox_sku_name.sql: SKU + description of the default variant, else the BOM item
               coalesce(nullif(trim(v_comp -> 'default' ->> 'sku'), ''),
                        (select nullif(trim(i."SKU"), '') from public."Items" i
                          where i."Code" = coalesce(v_comp ->> 'main_item_code', v_comp ->> 'bom_item_no') limit 1))::text,
               coalesce(nullif(trim(v_comp -> 'default' ->> 'description'), ''),
                        (select coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), '')) from public."Items" i
                          where i."Code" = coalesce(v_comp -> 'default' ->> 'item_code', v_comp ->> 'main_item_code', v_comp ->> 'bom_item_no') limit 1),
                        nullif(trim(v_comp ->> 'bom_item_name'), ''))::text;
    end loop;
  end loop;
end;
$$;

grant execute on function public.staff_get_online_order_set_stock(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: the new columns are there.
select p.proname::text as function_name, pg_get_function_result(p.oid) as returns
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('staff_get_lines_stock_by_warehouse', 'staff_get_document_stock_by_warehouse', 'staff_get_online_order_set_stock')
order by 1;
