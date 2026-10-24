-- Change the Warehouse on an already-created Purchase Order, per "can you help me edit the purchase
-- orders once created.. i notice that the warehouse cannot be changed if PO is created".
--
-- Run AFTER supabase_purchase_order_header_warehouse.sql (adds PurchaseOrders."WarehouseId"/
-- "WarehouseName"). Safe to re-run.
--
-- Until now the header warehouse could only be picked on a New PO; once created it was shown
-- read-only. This RPC changes it on an OPEN order and moves the lines with it, the same way the
-- New PO card does when its header warehouse is switched (applyHeaderWarehouseToNewPoLines in
-- js/purchaseOrders.js): a line that was following the header (same warehouse as the old header,
-- or none) moves to the new one; a line deliberately sent to a different warehouse keeps it.
--
-- Blocked once ANYTHING has been received on the order - received stock has already landed in the
-- old warehouse (Item Ledger receipt entries), so moving the order afterwards would leave its
-- lines saying one warehouse while the stock sits in another. Same "locked once received" rule the
-- line Qty/Cost/UoM editors already follow (supabase_purchase_order_line_quantity_edit.sql).
--
-- Any active staff (is_staff_authorized), like Payment Method - picking the warehouse at creation
-- is open to any staff too, so fixing a wrong pick should be as well.

drop function if exists public.staff_set_purchase_order_warehouse(text, text, text, text, text);

create or replace function public.staff_set_purchase_order_warehouse(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_warehouse_id text default null,
  p_warehouse_name text default null
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_warehouse_id text := nullif(trim(coalesce(p_warehouse_id, '')), '');
  v_warehouse_name text := nullif(trim(coalesce(p_warehouse_name, '')), '');
  v_old_warehouse_id text;
  v_lines_moved int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "WarehouseId" into v_old_warehouse_id
  from public."PurchaseOrders"
  where "PONo" = p_po_no
  for update;

  if not found then
    raise exception 'Purchase Order "%" not found - it may already be posted.', p_po_no;
  end if;

  if v_warehouse_id is not null then
    -- The name is taken from the warehouse itself, not trusted from the caller.
    select "Name" into v_warehouse_name from public."Warehouses" where "ID" = v_warehouse_id;
    if not found then
      raise exception 'Warehouse "%" not found.', v_warehouse_id;
    end if;
  else
    v_warehouse_name := null;
  end if;

  if exists (
    select 1 from public."PurchaseOrderLines"
    where "PONo" = p_po_no and coalesce("QtyReceived", 0) > 0
  ) then
    raise exception 'Items have already been received on this Purchase Order - its warehouse can no longer be changed.';
  end if;

  update public."PurchaseOrders"
     set "WarehouseId" = v_warehouse_id,
         "WarehouseName" = v_warehouse_name
   where "PONo" = p_po_no;

  update public."PurchaseOrderLines"
     set "WarehouseId" = v_warehouse_id,
         "WarehouseName" = v_warehouse_name
   where "PONo" = p_po_no
     and ("WarehouseId" is null or "WarehouseId" is not distinct from v_old_warehouse_id);
  get diagnostics v_lines_moved = row_count;

  return v_lines_moved;
end;
$$;

grant execute on function public.staff_set_purchase_order_warehouse(text, text, text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect exactly one row with has_anon_execute = true.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_set_purchase_order_warehouse';
