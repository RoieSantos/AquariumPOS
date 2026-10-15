-- "Stock" FactBox on the LISTS (Online / Walk-in Orders, Advance Orders, Transfer Orders, Purchase
-- Orders) - per "can you do it on the list level?". The selected row's lines with their on-hand per
-- warehouse, without opening the card.
--
-- staff_get_document_stock_by_warehouse(p_doc_type, p_doc_no): reads the document's lines itself
-- (a list row doesn't carry them) and hands them to staff_get_lines_stock_by_warehouse - same item
-- resolution and stock source (Item Ledger; IN_STOCK serials for Aquarium / Stand / Sump).
--   'online'   OnlineOrderLines        - badge warehouse = the order's LocationID
--   'advance'  AdvanceOrderLines       - the order's Warehouse (name)
--   'transfer' Transfer_Line           - the From Warehouse ID
--   'purchase' PurchaseOrderLines      - the line's own WarehouseId
-- Lines that aren't a stock item return no rows.
--
-- Read-only, staff-level auth. Run AFTER supabase_lines_stock_by_warehouse.sql. Safe to re-run.

drop function if exists public.staff_get_document_stock_by_warehouse(text, text, text, text);

create or replace function public.staff_get_document_stock_by_warehouse(
  p_admin_username text,
  p_admin_password text,
  p_doc_type text,
  p_doc_no text
)
returns table(line_key text, item_code text, variant_id text, label text, doc_warehouse text, source text,
              warehouse_id text, warehouse_name text, is_stock_warehouse boolean, quantity numeric)
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
           st.warehouse_id, st.warehouse_name, st.is_stock_warehouse, st.quantity
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
