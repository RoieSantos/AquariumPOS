-- Restore the Purchase Order line readers to their current shape - per "i already had that bag but
-- changing it does not work" (A-038, PO-0056: saved as BAG x 9, but the screen kept showing PCS).
--
-- Cause: staff_list_purchase_order_lines / staff_list_posted_purchase_order_lines were back on an
-- older version (supabase_item_cost_and_po_line_cost.sql, re-run 2026-10-02) that returns no
-- uom_code / qty_per_uom / quantity_uom / unit_cost_uom / variant_code / variant_name. The UoM change
-- saved fine (staff_set_purchase_order_line_uom), but the reader never returned the unit, so the
-- grid fell back to the base unit, the base quantity and the base cost - and the Variant picker
-- always read "(No variant)". Same for the printed PO and Posted Purchase Orders.
--
-- These two bodies are copied verbatim from supabase_purchase_order_line_variant.sql (the newest
-- version of both); ONLY these two functions are redefined, so nothing else that file defines gets
-- reverted. Safe to re-run. Ends with a check: both readers' result columns + PO-0056's lines.

drop function if exists public.staff_list_purchase_order_lines(text, text, text);

create or replace function public.staff_list_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric, vendor_item_no text, uom_code text, qty_per_uom numeric, quantity_uom numeric, unit_cost_uom numeric, variant_code text, variant_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- line_cost is computed here rather than in the browser so the PO total is derived one way
  -- only, and stays right for any other caller that reads these lines.
  return query
    select l."EntryNo", l."ItemCode"::text, l."ItemName"::text, l."WarehouseId"::text, l."WarehouseName"::text,
           l."Quantity", l."QtyReceived", l."Description"::text, l."UnitCost",
           round(coalesce(l."UnitCost", 0) * l."Quantity", 2),
           iv."VendorItemNo"::text,
           l."UnitOfMeasureCode"::text, l."QtyPerUnitOfMeasure", l."QuantityUom",
           l."UnitCost" * coalesce(l."QtyPerUnitOfMeasure", 1),
           l."VariantCode"::text, l."VariantName"::text
    from public."PurchaseOrderLines" l
    join public."PurchaseOrders" po on po."PONo" = l."PONo"
    left join public."ItemVendors" iv
      on iv."ItemCode" = l."ItemCode" and iv."VendorCode" = po."VendorCode"
    where l."PONo" = p_po_no
    order by l."EntryNo";
end;
$$;

grant execute on function public.staff_list_purchase_order_lines(text, text, text) to anon;

drop function if exists public.staff_list_posted_purchase_order_lines(text, text, text);

create or replace function public.staff_list_posted_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric, vendor_item_no text, uom_code text, qty_per_uom numeric, quantity_uom numeric, unit_cost_uom numeric, variant_code text, variant_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Posted lines cost out against what was actually RECEIVED, not what was ordered.
  return query
    select l."EntryNo", l."ItemCode"::text, l."ItemName"::text, l."WarehouseId"::text, l."WarehouseName"::text,
           l."Quantity", l."QtyReceived", l."Description"::text, l."UnitCost",
           round(coalesce(l."UnitCost", 0) * coalesce(l."QtyReceived", 0), 2),
           iv."VendorItemNo"::text,
           l."UnitOfMeasureCode"::text, l."QtyPerUnitOfMeasure", l."QuantityUom",
           l."UnitCost" * coalesce(l."QtyPerUnitOfMeasure", 1),
           l."VariantCode"::text, l."VariantName"::text
    from public."PostedPurchaseOrderLines" l
    join public."PostedPurchaseOrders" po on po."PONo" = l."PONo"
    left join public."ItemVendors" iv
      on iv."ItemCode" = l."ItemCode" and iv."VendorCode" = po."VendorCode"
    where l."PONo" = p_po_no
    order by l."EntryNo";
end;
$$;

grant execute on function public.staff_list_posted_purchase_order_lines(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Check: both readers should now list uom_code ... variant_name; PO-0056's lines as the grid will show them.
select 'reader' as section, p.proname::text as name, pg_get_function_result(p.oid) as detail
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('staff_list_purchase_order_lines', 'staff_list_posted_purchase_order_lines')
union all
select 'po line', l."PONo" || ' #' || l."EntryNo" || ' ' || l."ItemCode",
       'ordered ' || coalesce(l."QuantityUom"::text, '?') || ' ' || coalesce(l."UnitOfMeasureCode", '?')
         || ' (= ' || l."Quantity" || ' base) at ' || coalesce((l."UnitCost" * coalesce(l."QtyPerUnitOfMeasure", 1))::text, '-')
         || ' per ' || coalesce(l."UnitOfMeasureCode", 'unit') || ' (' || coalesce(l."UnitCost"::text, '-') || ' per base)'
  from public."PurchaseOrderLines" l
 where l."PONo" = 'PO-0056'
order by 1, 2;
