-- Editing an existing (not yet posted) Purchase Order's lines - per direct request: "in the
-- existing purchase order can we add more products and remove an existing item. Only super user
-- can do this". Gated by is_admin_authorized (super users only), unlike the rest of the Purchase
-- Orders RPCs which are is_staff_authorized (any active staff) - same elevated-gate pattern as
-- Warehouse/Item/Category Setup's admin_* functions in supabase_warehouses_items_tables.sql.
--
-- Both only ever touch the live PurchaseOrderLines table - once a PO is posted it moves to
-- PostedPurchaseOrderLines (supabase_purchase_order_receiving.sql) and these functions simply
-- won't find it (PONo/EntryNo lookups fail naturally), so a posted PO's permanent record can't be
-- edited after the fact.

drop function if exists public.staff_add_purchase_order_line(text, text, text, text, text, text, text, numeric);

-- Adds a brand new line to an existing PO - same shape as a Stock On Hand-generated line
-- (ItemCode/ItemName/WarehouseId/WarehouseName/Quantity), QtyReceived starts at 0. Returns the new
-- EntryNo so the caller can refresh just that row if it wants to.
create or replace function public.staff_add_purchase_order_line(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_item_code text,
  p_item_name text,
  p_warehouse_id text,
  p_warehouse_name text,
  p_quantity numeric
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry_no bigint;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can edit an existing Purchase Order.';
  end if;

  if not exists (select 1 from public."PurchaseOrders" where "PONo" = p_po_no) then
    raise exception 'Purchase Order "%" not found - it may already be posted.', p_po_no;
  end if;

  if p_item_code is null or trim(p_item_code) = '' then
    raise exception 'An item is required.';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be greater than 0.';
  end if;

  insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity")
  values (
    p_po_no,
    trim(p_item_code),
    coalesce(nullif(trim(p_item_name), ''), trim(p_item_code)),
    nullif(trim(coalesce(p_warehouse_id, '')), ''),
    nullif(trim(coalesce(p_warehouse_name, '')), ''),
    p_quantity
  )
  returning "EntryNo" into v_entry_no;

  return v_entry_no;
end;
$$;

grant execute on function public.staff_add_purchase_order_line(text, text, text, text, text, text, text, numeric) to anon;

drop function if exists public.staff_remove_purchase_order_line(text, text, bigint);

-- Removes a line outright - blocked once anything has been received against it (QtyReceived > 0),
-- since that quantity was already pushed to Pancake as real stock (see
-- staff_receive_purchase_order_lines in supabase_purchase_order_pancake_sync.sql) and removing the
-- line here would silently lose the only local record of that already-happened stock-in.
create or replace function public.staff_remove_purchase_order_line(
  p_admin_username text,
  p_admin_password text,
  p_entry_no bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_qty_received numeric;
  v_item_code text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can edit an existing Purchase Order.';
  end if;

  select "QtyReceived", "ItemCode" into v_qty_received, v_item_code
  from public."PurchaseOrderLines"
  where "EntryNo" = p_entry_no;

  if not found then
    raise exception 'Purchase Order line not found - it may already be removed.';
  end if;

  if v_qty_received > 0 then
    raise exception 'Cannot remove "%": % unit(s) already received against this line (and pushed to Pancake) - it can no longer be removed.', v_item_code, v_qty_received;
  end if;

  delete from public."PurchaseOrderLines" where "EntryNo" = p_entry_no;
end;
$$;

grant execute on function public.staff_remove_purchase_order_line(text, text, bigint) to anon;
