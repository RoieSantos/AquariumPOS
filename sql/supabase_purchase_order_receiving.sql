-- Purchase Order receiving + posting - per direct request: "can we implement receiving 'Qty
-- Received' and posting of purchase order going to Posted Purchase orders". Extends
-- supabase_purchase_orders.sql (which deliberately had "no status tracking beyond" create/print/
-- delete) with a partial-friendly receive workflow and a permanent archive, mirroring the existing
-- Transfer Order -> Posted Transfer Order pattern (supabase_posted_transfer_orders_tables.sql):
--   - "QtyReceived" is a running cumulative total per line (same partial-receive shape as
--     Transfer_Line's "Qty Received") - staff can receive a vendor delivery across several
--     separate actions as stock actually arrives, not just one all-or-nothing click.
--   - "Post" is a distinct, manually-triggered action (per the request's own wording: receiving,
--     THEN posting) rather than automatic once every line is fully received like Transfer Orders -
--     a vendor short-shipment is common and permanent, so a PO needs to be closeable at less than
--     100% received without staff being stuck waiting on a quantity that's never coming.
--
-- Still fully portal-side and unrelated to the desktop's own dbo.PurchaseHeader/lines, same as
-- supabase_purchase_orders.sql's original scope - posting here does NOT touch Items.QuantityInStock
-- or Pancake in any way, it only moves the record from the live PurchaseOrders/PurchaseOrderLines
-- tables into a permanent PostedPurchaseOrders/PostedPurchaseOrderLines archive. Real stock still
-- has to be adjusted wherever it actually lives (Pancake), same as every other portal-only record.

alter table public."PurchaseOrderLines" add column if not exists "QtyReceived" numeric(18, 2) not null default 0;

create table if not exists public."PostedPurchaseOrders" (
    "PONo" varchar(50) primary key,
    "VendorCode" varchar(50) not null,
    "OrderDate" date not null,
    "Notes" varchar(1000),
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null,
    "PostedBy" varchar(100),
    "PostedAtUtc" timestamptz not null default now()
);

-- Denormalizes ItemName/WarehouseName same as the live PurchaseOrderLines - a posted PO is a
-- point-in-time record, so it should keep reading the same even if an item/warehouse is later
-- renamed or deactivated.
create table if not exists public."PostedPurchaseOrderLines" (
    "EntryNo" bigint generated always as identity primary key,
    "PONo" varchar(50) not null references public."PostedPurchaseOrders"("PONo") on delete cascade,
    "ItemCode" varchar(200) not null,
    "ItemName" varchar(255) not null,
    "WarehouseId" varchar(200),
    "WarehouseName" varchar(200),
    "Quantity" numeric(18, 2) not null,
    "QtyReceived" numeric(18, 2) not null default 0
);

create index if not exists "IX_PostedPurchaseOrderLines_PONo" on public."PostedPurchaseOrderLines" ("PONo");
create index if not exists "IX_PostedPurchaseOrders_VendorCode" on public."PostedPurchaseOrders" ("VendorCode");

alter table public."PostedPurchaseOrders" enable row level security;
alter table public."PostedPurchaseOrderLines" enable row level security;
revoke all on public."PostedPurchaseOrders" from anon, authenticated;
revoke all on public."PostedPurchaseOrderLines" from anon, authenticated;

drop function if exists public.staff_list_purchase_order_lines(text, text, text);

-- Widened to also expose the running QtyReceived total (return columns widening needs the
-- explicit drop above - Postgres 42P13).
create or replace function public.staff_list_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "EntryNo", "ItemCode"::text, "ItemName"::text, "WarehouseId"::text, "WarehouseName"::text, "Quantity", "QtyReceived"
    from public."PurchaseOrderLines"
    where "PONo" = p_po_no
    order by "EntryNo";
end;
$$;

grant execute on function public.staff_list_purchase_order_lines(text, text, text) to anon;

drop function if exists public.staff_list_purchase_orders(text, text, text, int, int);

-- Widened to also expose total_received_quantity, so the list page can show a receiving progress
-- badge per PO without a second round trip per row.
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
  total_received_quantity numeric,
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
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
      po."CreatedBy"::text, po."CreatedAtUtc",
      count(l."EntryNo"), coalesce(sum(l."Quantity"), 0), coalesce(sum(l."QtyReceived"), 0),
      count(*) over()
    from public."PurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    left join public."PurchaseOrderLines" l on l."PONo" = po."PONo"
    where p_search is null or trim(p_search) = ''
      or po."PONo" ilike '%' || p_search || '%'
      or v."Name" ilike '%' || p_search || '%'
    group by po."PONo", po."VendorCode", v."Name", po."OrderDate", po."Notes", po."CreatedBy", po."CreatedAtUtc"
    order by po."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.staff_list_purchase_orders(text, text, text, int, int) to anon;

drop function if exists public.staff_receive_purchase_order_lines(text, text, text, jsonb);

-- p_lines: JSON array of {entry_no, quantity} - `quantity` is the amount being received in THIS
-- action (not a new total), added to that line's existing cumulative QtyReceived and capped at the
-- line's ordered Quantity - same running-total/cap pattern as Transfer_Line's Qty Received
-- (see receiveTransferOrder in transferOrders.js). Lines omitted or with a zero/blank quantity are
-- simply left untouched.
create or replace function public.staff_receive_purchase_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_lines jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line jsonb;
  v_entry_no bigint;
  v_quantity numeric;
  v_updated_count int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (select 1 from public."PurchaseOrders" where "PONo" = p_po_no) then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one line with a quantity is required.';
  end if;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_entry_no := nullif(v_line ->> 'entry_no', '')::bigint;
    v_quantity := nullif(v_line ->> 'quantity', '')::numeric;
    if v_entry_no is null or v_quantity is null or v_quantity <= 0 then
      continue;
    end if;

    update public."PurchaseOrderLines"
    set "QtyReceived" = least("Quantity", "QtyReceived" + v_quantity)
    where "EntryNo" = v_entry_no and "PONo" = p_po_no;

    if found then
      v_updated_count := v_updated_count + 1;
    end if;
  end loop;

  if v_updated_count = 0 then
    raise exception 'No matching line(s) with a quantity greater than zero were received.';
  end if;
end;
$$;

grant execute on function public.staff_receive_purchase_order_lines(text, text, text, jsonb) to anon;

drop function if exists public.staff_post_purchase_order(text, text, text);

-- Archives a Purchase Order (header + lines, with whatever QtyReceived has accumulated so far)
-- into PostedPurchaseOrders/PostedPurchaseOrderLines and removes it from the live tables - same
-- "insert into Posted first, then delete from live" order as archiveReceivedTransferOrder in
-- transferOrders.js, so a failure partway through leaves a recoverable duplicate rather than
-- losing the order. Deliberately NOT gated on full receipt - a vendor short-shipment is common and
-- permanent, so staff need to be able to close a PO at less than 100% received.
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

  insert into public."PostedPurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived")
  select "PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived"
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no;

  delete from public."PurchaseOrders" where "PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_post_purchase_order(text, text, text) to anon;

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
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text,
      po."CreatedBy"::text, po."CreatedAtUtc", po."PostedBy"::text, po."PostedAtUtc",
      count(l."EntryNo"), coalesce(sum(l."Quantity"), 0), coalesce(sum(l."QtyReceived"), 0),
      count(*) over()
    from public."PostedPurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    left join public."PostedPurchaseOrderLines" l on l."PONo" = po."PONo"
    where p_search is null or trim(p_search) = ''
      or po."PONo" ilike '%' || p_search || '%'
      or v."Name" ilike '%' || p_search || '%'
    group by po."PONo", po."VendorCode", v."Name", po."OrderDate", po."Notes", po."CreatedBy", po."CreatedAtUtc", po."PostedBy", po."PostedAtUtc"
    order by po."PostedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.staff_list_posted_purchase_orders(text, text, text, int, int) to anon;

drop function if exists public.staff_get_posted_purchase_order(text, text, text);

create or replace function public.staff_get_posted_purchase_order(p_admin_username text, p_admin_password text, p_po_no text)
returns table(po_no text, vendor_code text, vendor_name text, order_date date, notes text, created_by text, created_at_utc timestamptz, posted_by text, posted_at_utc timestamptz)
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
           po."CreatedBy"::text, po."CreatedAtUtc", po."PostedBy"::text, po."PostedAtUtc"
    from public."PostedPurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    where po."PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_get_posted_purchase_order(text, text, text) to anon;

drop function if exists public.staff_list_posted_purchase_order_lines(text, text, text);

create or replace function public.staff_list_posted_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "EntryNo", "ItemCode"::text, "ItemName"::text, "WarehouseId"::text, "WarehouseName"::text, "Quantity", "QtyReceived"
    from public."PostedPurchaseOrderLines"
    where "PONo" = p_po_no
    order by "EntryNo";
end;
$$;

grant execute on function public.staff_list_posted_purchase_order_lines(text, text, text) to anon;
