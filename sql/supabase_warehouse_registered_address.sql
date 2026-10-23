-- Registered address per warehouse on documents - per "can we do registered address depends on the
-- warehouse ?". Each branch can have its own BIR registration, so the letterhead "Address:" on the Order
-- Confirmation, both Invoices and the Xendit Payment Receipt now shows the registered address of the
-- order's branch, falling back to General Setup's Company Info address when the branch has none.
--
-- 1. Warehouses."RegisteredAddress" - edited on Warehouse Setup (new column next to Address / Contact
--    No.). It's separate from "Address", which is the pickup / delivery address (geocoded for delivery
--    distance) and is still what the documents show under the branch details.
-- 2. public_get_order_letterhead(order ref) - the order's branch and its registered address. An AO-
--    order uses its Online Orders branch (LocationID) once confirmed, else its Location name, the same
--    name match the receipt functions use; an Online Order ID uses its LocationID. js/orderDocument.js
--    (orderLetterheadInfo) puts it into the letterhead.
--
-- Run AFTER supabase_order_receipt_letterhead.sql. Safe to re-run.
-- Needs warehouseSetup.js ?v=regaddr1, orderDocument.js ?v=regaddr1 on online-order-receipt.html,
-- online-order-invoice.html, gma-order-invoice.html and payment-receipt.html.

alter table public."Warehouses" add column if not exists "RegisteredAddress" varchar(500);

-- Same as supabase_order_receipt_letterhead.sql + registered_address (return type changes, so drop first).
drop function if exists public.admin_list_warehouses(text, text, int, int);

create or replace function public.admin_list_warehouses(p_admin_username text, p_admin_password text, p_page int default 1, p_page_size int default 50)
returns table(
  id text,
  name text,
  is_production_warehouse boolean,
  is_stock_warehouse boolean,
  is_active boolean,
  sales_target numeric,
  synced_at_utc timestamptz,
  address text,
  geocode_status text,
  contact_no text,
  registered_address text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "ID"::text, "Name"::text, "IsProductionWarehouse", "IsStockWarehouse", "IsActive", "SalesTarget", "SyncedAtUtc",
           "Address"::text, "GeocodeStatus"::text, "ContactNo"::text, "RegisteredAddress"::text,
           count(*) over()
    from public."Warehouses"
    order by "Name"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_warehouses(text, text, int, int) to anon;

drop function if exists public.admin_update_warehouse_registered_address(text, text, text, text);

create or replace function public.admin_update_warehouse_registered_address(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
  p_registered_address text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."Warehouses"
  set "RegisteredAddress" = left(nullif(trim(p_registered_address), ''), 500)
  where "ID" = p_warehouse_id;
end;
$$;

grant execute on function public.admin_update_warehouse_registered_address(text, text, text, text) to anon;

-- The order's branch + registered address, for the document letterhead. Public like the receipt
-- functions themselves - it only returns a branch name and the address printed on our documents.
drop function if exists public.public_get_order_letterhead(text);

create or replace function public.public_get_order_letterhead(p_order_ref text)
returns table(warehouse_name text, registered_address text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_ref text := trim(coalesce(p_order_ref, ''));
  v_ao public."AutomatedOrders"%rowtype;
  v_location_id text;
  v_location_name text;
  v_name text;
  v_reg text;
begin
  if v_ref = '' then
    return;
  end if;

  select * into v_ao from public."AutomatedOrders" where upper("OrderNo") = upper(v_ref);
  if found then
    select o."LocationID"::text into v_location_id from public."OnlineOrders" o
     where o."OrderID" = coalesce(nullif(trim(v_ao."PancakeReceiptNo"), ''), v_ao."OrderNo");
    v_location_name := coalesce(nullif(trim(v_ao."Location"), ''), 'Amaya');
  else
    select o."LocationID"::text into v_location_id from public."OnlineOrders" o where o."OrderID" = v_ref;
  end if;

  if v_location_id is not null then
    select wh."Name"::text, nullif(trim(wh."RegisteredAddress"), '')::text into v_name, v_reg
      from public."Warehouses" wh where wh."ID"::text = v_location_id;
  end if;
  if v_name is null and v_location_name is not null then
    select wh."Name"::text, nullif(trim(wh."RegisteredAddress"), '')::text into v_name, v_reg
      from public."Warehouses" wh where wh."Name" ilike '%' || v_location_name || '%'
     order by wh."Name" limit 1;
  end if;
  if v_name is null then
    return;
  end if;

  return query select v_name, v_reg;
end;
$$;

grant execute on function public.public_get_order_letterhead(text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: every warehouse and the registered address its documents will show.
select w."Name"::text as warehouse,
       coalesce(nullif(trim(w."RegisteredAddress"), ''), '(not set - documents use General Setup address)') as registered_address,
       coalesce(nullif(trim(w."Address"), ''), '-') as pickup_address
  from public."Warehouses" w
 where w."IsActive"
 order by w."Name";
