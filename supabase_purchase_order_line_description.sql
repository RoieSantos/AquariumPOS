-- Purchase Order line Description - per direct request: "add another field for free text
-- Description" alongside the Item/Variant fields (New Purchase Order modal and the existing-PO
-- "Add Item" edit flow - js/purchaseOrders.js). Free text, independent of ItemName - lets staff
-- note extra ordering specifics (color, size, packaging, a vendor-specific spec, etc.) that don't
-- belong in the catalog item's own name.
--
-- Widens PurchaseOrderLines (supabase_purchase_orders.sql) and its posted-archive twin
-- PostedPurchaseOrderLines (supabase_purchase_order_receiving.sql), and every function that reads
-- or writes a PO line, so a line's Description survives Receive/Post the same way ItemName does.
-- Functions whose signature only widens a jsonb payload or a returned column keep "create or
-- replace" in place; ones whose return table shape changes need the explicit drop first (Postgres
-- 42P13), same convention the receiving file already used for QtyReceived.

alter table public."PurchaseOrderLines" add column if not exists "Description" varchar(500);
alter table public."PostedPurchaseOrderLines" add column if not exists "Description" varchar(500);

-- staff_create_purchase_order: p_lines gains an optional "description" key per line (same jsonb
-- param, no signature change - no drop needed).
create or replace function public.staff_create_purchase_order(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_notes text,
  p_lines jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_po_no text;
  v_vendor_code text := nullif(trim(coalesce(p_vendor_code, '')), '');
  v_line jsonb;
  v_quantity numeric;
  v_line_count int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_vendor_code is null then
    raise exception 'A vendor is required to create a Purchase Order.';
  end if;

  if not exists (select 1 from public."Vendors" where "VendorCode" = v_vendor_code) then
    raise exception 'Vendor "%" not found.', v_vendor_code;
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one item with a quantity is required.';
  end if;

  v_po_no := public._next_no_series_number('PURCHASE-ORDER', '');

  insert into public."PurchaseOrders" ("PONo", "VendorCode", "Notes", "CreatedBy")
  values (v_po_no, v_vendor_code, nullif(trim(coalesce(p_notes, '')), ''), p_admin_username);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_quantity := (v_line ->> 'quantity')::numeric;
    if v_quantity is null or v_quantity <= 0 then
      continue;
    end if;

    if v_line ->> 'item_code' is null or trim(v_line ->> 'item_code') = '' then
      continue;
    end if;

    insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "Description")
    values (
      v_po_no,
      trim(v_line ->> 'item_code'),
      coalesce(nullif(trim(v_line ->> 'item_name'), ''), trim(v_line ->> 'item_code')),
      nullif(trim(coalesce(v_line ->> 'warehouse_id', '')), ''),
      nullif(trim(coalesce(v_line ->> 'warehouse_name', '')), ''),
      v_quantity,
      nullif(trim(coalesce(v_line ->> 'description', '')), '')
    );
    v_line_count := v_line_count + 1;
  end loop;

  if v_line_count = 0 then
    raise exception 'At least one item with a quantity greater than zero is required.';
  end if;

  return v_po_no;
end;
$$;

drop function if exists public.staff_add_purchase_order_line(text, text, text, text, text, text, text, numeric);

create or replace function public.staff_add_purchase_order_line(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_item_code text,
  p_item_name text,
  p_warehouse_id text,
  p_warehouse_name text,
  p_quantity numeric,
  p_description text default null
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

  insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "Description")
  values (
    p_po_no,
    trim(p_item_code),
    coalesce(nullif(trim(p_item_name), ''), trim(p_item_code)),
    nullif(trim(coalesce(p_warehouse_id, '')), ''),
    nullif(trim(coalesce(p_warehouse_name, '')), ''),
    p_quantity,
    nullif(trim(coalesce(p_description, '')), '')
  )
  returning "EntryNo" into v_entry_no;

  return v_entry_no;
end;
$$;

grant execute on function public.staff_add_purchase_order_line(text, text, text, text, text, text, text, numeric, text) to anon;

drop function if exists public.staff_list_purchase_order_lines(text, text, text);

create or replace function public.staff_list_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "EntryNo", "ItemCode"::text, "ItemName"::text, "WarehouseId"::text, "WarehouseName"::text, "Quantity", "QtyReceived", "Description"::text
    from public."PurchaseOrderLines"
    where "PONo" = p_po_no
    order by "EntryNo";
end;
$$;

grant execute on function public.staff_list_purchase_order_lines(text, text, text) to anon;

drop function if exists public.staff_list_posted_purchase_order_lines(text, text, text);

create or replace function public.staff_list_posted_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "EntryNo", "ItemCode"::text, "ItemName"::text, "WarehouseId"::text, "WarehouseName"::text, "Quantity", "QtyReceived", "Description"::text
    from public."PostedPurchaseOrderLines"
    where "PONo" = p_po_no
    order by "EntryNo";
end;
$$;

grant execute on function public.staff_list_posted_purchase_order_lines(text, text, text) to anon;

-- staff_post_purchase_order: same signature, just carries Description across into the archive too
-- (no drop needed).
create or replace function public.staff_post_purchase_order(
  p_admin_username text,
  p_admin_password text,
  p_po_no text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (select 1 from public."PurchaseOrders" where "PONo" = p_po_no) then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  insert into public."PostedPurchaseOrders" ("PONo", "VendorCode", "OrderDate", "Notes", "CreatedBy", "CreatedAtUtc", "PostedBy")
  select "PONo", "VendorCode", "OrderDate", "Notes", "CreatedBy", "CreatedAtUtc", p_admin_username
  from public."PurchaseOrders"
  where "PONo" = p_po_no;

  insert into public."PostedPurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived", "Description")
  select "PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived", "Description"
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no;

  delete from public."PurchaseOrders" where "PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_post_purchase_order(text, text, text) to anon;
