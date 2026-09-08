-- Purchase Order header Warehouse, per "if user doing PO can you default the warehouse into their
-- designated warehouse. Add the warehouse on the PO header too".
--
-- Until now a Warehouse only existed per LINE, which meant an order raised for one branch had to
-- have that branch re-picked on every line, and the order as a whole could not say where it was
-- being ordered for. The header now carries one, denormalized as Id + Name the same way the lines
-- already are (a PO is a point-in-time record - renaming or deactivating a warehouse later must
-- not rewrite what an existing order says).
--
-- The portal defaults it to the ordering user's own designated warehouse
-- (StaffUsers."WarehouseName", the same field Online Orders/Dashboard/Serial Tracker scope by) and
-- each line then inherits the header - see js/purchaseOrders.js. Both stay editable: ordering for
-- another branch is a normal thing to do, and a line can still name its own warehouse.

alter table public."PurchaseOrders" add column if not exists "WarehouseId" varchar(200);
alter table public."PurchaseOrders" add column if not exists "WarehouseName" varchar(200);

alter table public."PostedPurchaseOrders" add column if not exists "WarehouseId" varchar(200);
alter table public."PostedPurchaseOrders" add column if not exists "WarehouseName" varchar(200);

-- Carrying the header warehouse into the posted archive is done with a trigger rather than by
-- editing staff_post_purchase_order's INSERT. That function has been redefined by several
-- migrations already (receiving, then line descriptions, then line costs, then the GL posting
-- integration) and re-running any of those would silently drop a column added to its INSERT here.
-- The trigger is independent of which version is installed: posting inserts the PostedPurchaseOrders
-- row while the live PurchaseOrders row still exists (it is deleted afterwards), so the value is
-- always there to copy. Only fills what the insert left null, so an explicit value still wins.
create or replace function public._posted_purchase_order_fill_warehouse()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new."WarehouseId" is null and new."WarehouseName" is null then
    select po."WarehouseId", po."WarehouseName"
      into new."WarehouseId", new."WarehouseName"
    from public."PurchaseOrders" po
    where po."PONo" = new."PONo";
  end if;

  return new;
end;
$$;

drop trigger if exists "TR_PostedPurchaseOrders_FillWarehouse" on public."PostedPurchaseOrders";
create trigger "TR_PostedPurchaseOrders_FillWarehouse"
before insert on public."PostedPurchaseOrders"
for each row execute function public._posted_purchase_order_fill_warehouse();

-- staff_create_purchase_order: gains p_warehouse_id / p_warehouse_name.
--
-- Dropped BY OID rather than by a hard-coded signature. This function is called with named
-- arguments through PostgREST, so leaving the old 5-argument version in place beside the new
-- 7-argument one would make every call ambiguous (PGRST203, the same "Could not choose the best
-- candidate function" failure the item picker hit) - the old one must be gone, not just shadowed.
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'staff_create_purchase_order'
  loop
    raise notice 'Dropping overload: %', r.signature;
    execute format('drop function %s', r.signature);
  end loop;
end;
$$;

-- Body is the existing one (catalog-cost fallback per line from
-- supabase_item_cost_and_po_line_cost.sql, line descriptions from
-- supabase_purchase_order_line_description.sql) plus the header warehouse and the line-level
-- inheritance of it.
create or replace function public.staff_create_purchase_order(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_notes text,
  p_lines jsonb,
  p_warehouse_id text default null,
  p_warehouse_name text default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_po_no text;
  v_vendor_code text := nullif(trim(coalesce(p_vendor_code, '')), '');
  v_warehouse_id text := nullif(trim(coalesce(p_warehouse_id, '')), '');
  v_warehouse_name text := nullif(trim(coalesce(p_warehouse_name, '')), '');
  v_line jsonb;
  v_quantity numeric;
  v_item_code text;
  v_unit_cost numeric;
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

  -- A header warehouse is optional (Stock On Hand raises POs without one), but if an Id is given
  -- it has to be a real warehouse - a typo here would otherwise be inherited by every line.
  if v_warehouse_id is not null and not exists (select 1 from public."Warehouses" where "ID" = v_warehouse_id) then
    raise exception 'Warehouse "%" not found.', v_warehouse_id;
  end if;

  v_po_no := public._next_no_series_number('PURCHASE-ORDER', '');

  insert into public."PurchaseOrders" ("PONo", "VendorCode", "Notes", "CreatedBy", "WarehouseId", "WarehouseName")
  values (v_po_no, v_vendor_code, nullif(trim(coalesce(p_notes, '')), ''), p_admin_username, v_warehouse_id, v_warehouse_name);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_quantity := (v_line ->> 'quantity')::numeric;
    if v_quantity is null or v_quantity <= 0 then
      continue;
    end if;

    if v_line ->> 'item_code' is null or trim(v_line ->> 'item_code') = '' then
      continue;
    end if;

    v_item_code := trim(v_line ->> 'item_code');
    v_unit_cost := nullif(trim(coalesce(v_line ->> 'unit_cost', '')), '')::numeric;

    if v_unit_cost is null then
      select i."Cost" into v_unit_cost from public."Items" i where i."Code" = v_item_code;
    end if;

    if v_unit_cost is not null and v_unit_cost < 0 then
      raise exception 'Unit cost cannot be negative (item "%").', v_item_code;
    end if;

    -- A line that names no warehouse inherits the header's, so "everything on this order goes to
    -- my branch" needs saying once. A line that names one keeps it.
    insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "Description", "UnitCost")
    values (
      v_po_no,
      v_item_code,
      coalesce(nullif(trim(v_line ->> 'item_name'), ''), v_item_code),
      coalesce(nullif(trim(coalesce(v_line ->> 'warehouse_id', '')), ''), v_warehouse_id),
      coalesce(nullif(trim(coalesce(v_line ->> 'warehouse_name', '')), ''), v_warehouse_name),
      v_quantity,
      nullif(trim(coalesce(v_line ->> 'description', '')), ''),
      v_unit_cost
    );
    v_line_count := v_line_count + 1;
  end loop;

  if v_line_count = 0 then
    raise exception 'At least one item with a quantity greater than zero is required.';
  end if;

  return v_po_no;
end;
$$;

grant execute on function public.staff_create_purchase_order(text, text, text, text, jsonb, text, text) to anon;

-- The four header readers below all gain the warehouse. Return-table changes need the explicit
-- drop first (Postgres 42P13); the new columns are appended last, so any caller that does not
-- know about them yet keeps working unchanged.
drop function if exists public.staff_get_purchase_order(text, text, text);

create or replace function public.staff_get_purchase_order(p_admin_username text, p_admin_password text, p_po_no text)
returns table(po_no text, vendor_code text, vendor_name text, order_date date, notes text, created_by text, created_at_utc timestamptz, warehouse_id text, warehouse_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
           po."CreatedBy"::text, po."CreatedAtUtc", po."WarehouseId"::text, po."WarehouseName"::text
    from public."PurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    where po."PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_get_purchase_order(text, text, text) to anon;

drop function if exists public.staff_list_purchase_orders(text, text, text, int, int);

create or replace function public.staff_list_purchase_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  po_no text,
  vendor_code text,
  vendor_name text,
  order_date date,
  notes text,
  created_by text,
  created_at_utc timestamptz,
  line_count bigint,
  total_quantity numeric,
  total_count bigint,
  warehouse_name text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
      po."CreatedBy"::text, po."CreatedAtUtc",
      count(l."EntryNo"), coalesce(sum(l."Quantity"), 0),
      count(*) over(),
      po."WarehouseName"::text
    from public."PurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    left join public."PurchaseOrderLines" l on l."PONo" = po."PONo"
    where p_search is null or trim(p_search) = ''
      or po."PONo" ilike '%' || p_search || '%'
      or v."Name" ilike '%' || p_search || '%'
      or po."WarehouseName" ilike '%' || p_search || '%'
    group by po."PONo", po."VendorCode", v."Name", po."OrderDate", po."Notes", po."CreatedBy", po."CreatedAtUtc", po."WarehouseName"
    order by po."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.staff_list_purchase_orders(text, text, text, int, int) to anon;

drop function if exists public.staff_get_posted_purchase_order(text, text, text);

create or replace function public.staff_get_posted_purchase_order(p_admin_username text, p_admin_password text, p_po_no text)
returns table(po_no text, vendor_code text, vendor_name text, order_date date, notes text, created_by text, created_at_utc timestamptz, posted_by text, posted_at_utc timestamptz, warehouse_id text, warehouse_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
           po."CreatedBy"::text, po."CreatedAtUtc", po."PostedBy"::text, po."PostedAtUtc",
           po."WarehouseId"::text, po."WarehouseName"::text
    from public."PostedPurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    where po."PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_get_posted_purchase_order(text, text, text) to anon;

drop function if exists public.staff_list_posted_purchase_orders(text, text, text, int, int);

create or replace function public.staff_list_posted_purchase_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  po_no text,
  vendor_code text,
  vendor_name text,
  order_date date,
  notes text,
  created_by text,
  created_at_utc timestamptz,
  posted_by text,
  posted_at_utc timestamptz,
  line_count bigint,
  total_quantity numeric,
  total_received_quantity numeric,
  total_count bigint,
  warehouse_name text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
      po."CreatedBy"::text, po."CreatedAtUtc", po."PostedBy"::text, po."PostedAtUtc",
      count(l."EntryNo"), coalesce(sum(l."Quantity"), 0), coalesce(sum(l."QtyReceived"), 0),
      count(*) over(),
      po."WarehouseName"::text
    from public."PostedPurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    left join public."PostedPurchaseOrderLines" l on l."PONo" = po."PONo"
    where p_search is null or trim(p_search) = ''
      or po."PONo" ilike '%' || p_search || '%'
      or v."Name" ilike '%' || p_search || '%'
      or po."WarehouseName" ilike '%' || p_search || '%'
    group by po."PONo", po."VendorCode", v."Name", po."OrderDate", po."Notes", po."CreatedBy", po."CreatedAtUtc", po."PostedBy", po."PostedAtUtc", po."WarehouseName"
    order by po."PostedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.staff_list_posted_purchase_orders(text, text, text, int, int) to anon;

-- Backfill: existing open POs get their header warehouse from their own lines, when every line
-- already agrees on one. A PO whose lines span several warehouses (or name none) is left blank
-- rather than guessed at - the lines still say where each item goes.
update public."PurchaseOrders" po
   set "WarehouseId" = agreed."WarehouseId",
       "WarehouseName" = agreed."WarehouseName"
  from (
    select "PONo", min("WarehouseId") as "WarehouseId", min("WarehouseName") as "WarehouseName"
    from public."PurchaseOrderLines"
    where "WarehouseId" is not null
    group by "PONo"
    having count(distinct "WarehouseId") = 1
  ) as agreed
 where po."PONo" = agreed."PONo"
   and po."WarehouseId" is null;

update public."PostedPurchaseOrders" po
   set "WarehouseId" = agreed."WarehouseId",
       "WarehouseName" = agreed."WarehouseName"
  from (
    select "PONo", min("WarehouseId") as "WarehouseId", min("WarehouseName") as "WarehouseName"
    from public."PostedPurchaseOrderLines"
    where "WarehouseId" is not null
    group by "PONo"
    having count(distinct "WarehouseId") = 1
  ) as agreed
 where po."PONo" = agreed."PONo"
   and po."WarehouseId" is null;

notify pgrst, 'reload schema';

-- Verification. Expect one row per function, and staff_create_purchase_order's argument list must
-- end with "p_warehouse_id text, p_warehouse_name text". More than one row for any of them means
-- an older overload survived and PostgREST will not be able to choose between them.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'staff_create_purchase_order',
    'staff_get_purchase_order',
    'staff_list_purchase_orders',
    'staff_get_posted_purchase_order',
    'staff_list_posted_purchase_orders'
  )
order by p.proname, arguments;
