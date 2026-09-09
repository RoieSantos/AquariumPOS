-- Change a Purchase Order line's Unit of Measure while the order is open, per "on editing the PO
-- can we change the UOM?". Until now the unit could only be chosen as the line was created; a line
-- entered in pieces that turns out to be sold by the box had to be removed and re-added.
--
-- WHAT CHANGING IT DOES, and why. The quantity you TYPED stays put and the base quantity moves:
-- 5 at BOX(12) becomes 5 at CTN(48) - that is, 60 base becomes 240. This is BC's own behaviour
-- (Quantity holds, Quantity (Base) recalculates), and it is the reading that matches what someone
-- is actually doing when they change the unit: "it's five of the bigger ones", not "it's still
-- sixty pieces, re-expressed".
--
-- The unit COST does not move. It is stored per base unit (see supabase_units_of_measure.sql), and
-- what one piece costs does not change because of how it is packed. The price shown per ordering
-- unit does change, of course, since that is cost x the new conversion.
--
-- Blocked once anything has been received against the line, matching
-- staff_set_purchase_order_line_cost: that quantity has already been pushed to Pancake as real
-- stock, and restating it here would leave the two disagreeing about what arrived.

drop function if exists public.staff_set_purchase_order_line_uom(text, text, bigint, text);

create or replace function public.staff_set_purchase_order_line_uom(
  p_admin_username text,
  p_admin_password text,
  p_entry_no bigint,
  p_unit_of_measure_code text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line record;
  v_code text := upper(nullif(trim(coalesce(p_unit_of_measure_code, '')), ''));
  v_qty_per numeric;
  v_qty_uom numeric;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can edit an existing Purchase Order.';
  end if;

  select * into v_line from public."PurchaseOrderLines" where "EntryNo" = p_entry_no;

  if not found then
    raise exception 'Purchase Order line not found - it may already be posted.';
  end if;

  if coalesce(v_line."QtyReceived", 0) > 0 then
    raise exception 'This line has already been received - its unit of measure can no longer be changed.';
  end if;

  if v_code is null then
    raise exception 'A unit of measure is required.';
  end if;

  select "QtyPerUnitOfMeasure" into v_qty_per
  from public."ItemUnitsOfMeasure"
  where "ItemCode" = v_line."ItemCode" and "UnitOfMeasureCode" = v_code;

  if not found then
    raise exception 'Item "%" has no conversion for "%" - add it on the item card first.', v_line."ItemCode", v_code;
  end if;

  -- A line raised before units existed carries no QuantityUom; its Quantity was already the typed
  -- number, at a conversion of 1, so that is what carries over.
  v_qty_uom := coalesce(v_line."QuantityUom", v_line."Quantity");

  update public."PurchaseOrderLines"
     set "UnitOfMeasureCode" = v_code,
         "QtyPerUnitOfMeasure" = v_qty_per,
         "QuantityUom" = v_qty_uom,
         "Quantity" = v_qty_uom * v_qty_per
   where "EntryNo" = p_entry_no;
end;
$$;

grant execute on function public.staff_set_purchase_order_line_uom(text, text, bigint, text) to anon;

-- ============================================================================
-- unit_cost_uom on the line readers - the price per ORDERING unit.
--
-- Fixes a real inconsistency in what shipped with supabase_units_of_measure.sql: those screens
-- show a line's quantity in its ordering unit ("5 BOX") but its unit cost per BASE unit, so the
-- printed Purchase Order read "5 BOX x 40.00 = 2,400.00" - arithmetic that does not work, in front
-- of the vendor. The New Purchase Order grid was right (it enters and shows cost per unit); every
-- screen reading a saved line was wrong.
--
-- Derived here rather than in each page, so the four callers (Receive document, printed PO, posted
-- detail, posted reprint) cannot drift. unit_cost stays exactly as it was - base, which is what
-- costing and the GL consume - and this is the presentation figure beside it.
--
-- This file supersedes supabase_units_of_measure.sql for both functions.

drop function if exists public.staff_list_purchase_order_lines(text, text, text);

create or replace function public.staff_list_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric, vendor_item_no text, uom_code text, qty_per_uom numeric, quantity_uom numeric, unit_cost_uom numeric)
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
           l."UnitCost" * coalesce(l."QtyPerUnitOfMeasure", 1)
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
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric, vendor_item_no text, uom_code text, qty_per_uom numeric, quantity_uom numeric, unit_cost_uom numeric)
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
           l."UnitCost" * coalesce(l."QtyPerUnitOfMeasure", 1)
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

-- Verification. One row per function; the two readers must end with "unit_cost_uom".
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'staff_set_purchase_order_line_uom',
    'staff_list_purchase_order_lines',
    'staff_list_posted_purchase_order_lines'
  )
order by p.proname, arguments;
