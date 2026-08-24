-- Purchase Orders (Web Portal) - per direct request: "once I input the quantity on the stock on
-- hand can you convert it to Purchase Order? with the actual quantity that i requested". Simple
-- record scope (per direct choice over a fuller Draft/Sent/Received + auto-Vendor-Bill workflow):
-- one click on Stock On Hand's entered Quantity column generates a PO tied to a vendor, viewable/
-- printable/deletable, no status tracking beyond that.
--
-- Deliberately a NEW, separate concept from the desktop app's own dbo.PurchaseHeader/lines
-- (PurchaseHeaderForm.cs/PurchaseOrdersForm.cs/PurchaseOrderLinesForm.cs) - that local table has no
-- Vendor concept at all (just No./Description/PO Date/Received Date) and is never synced to
-- Supabase. This stays fully portal-side, tied to the Vendor system built this session (Vendors/
-- Items.VendorCode/VendorBills - supabase_vendor_tables.sql), same as everything else in that
-- system. No relation/sync between the two "Purchase Order" concepts.
--
-- Staff-gated (is_staff_authorized, not is_admin_authorized) throughout - matches Stock On Hand's
-- own access level (any active staff, not just super users), since this is generated directly from
-- that page. Vendor MASTER data management (Vendor Setup) stays super-user only as already built;
-- referencing an existing vendor to create a PO does not.

create table if not exists public."PurchaseOrders" (
    "PONo" varchar(50) primary key,
    "VendorCode" varchar(50) not null,
    "OrderDate" date not null default (now() at time zone 'Asia/Manila')::date,
    "Notes" varchar(1000),
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now()
);

-- Denormalizes ItemName/WarehouseName at creation time (same convention as AutomatedOrderLines -
-- see supabase_automated_orders_tables.sql) rather than joining live to Items/Warehouses - a PO is
-- a point-in-time record of what was actually requested, so it should keep reading the same even
-- if an item gets renamed or a warehouse gets renamed/deactivated later.
create table if not exists public."PurchaseOrderLines" (
    "EntryNo" bigint generated always as identity primary key,
    "PONo" varchar(50) not null references public."PurchaseOrders"("PONo") on delete cascade,
    "ItemCode" varchar(200) not null,
    "ItemName" varchar(255) not null,
    "WarehouseId" varchar(200),
    "WarehouseName" varchar(200),
    "Quantity" numeric(18, 2) not null
);

create index if not exists "IX_PurchaseOrderLines_PONo" on public."PurchaseOrderLines" ("PONo");
create index if not exists "IX_PurchaseOrders_VendorCode" on public."PurchaseOrders" ("VendorCode");

alter table public."PurchaseOrders" enable row level security;
alter table public."PurchaseOrderLines" enable row level security;
revoke all on public."PurchaseOrders" from anon, authenticated;
revoke all on public."PurchaseOrderLines" from anon, authenticated;

-- Numbering reuses the existing generic No. Series system (supabase_no_series_tables.sql), same as
-- Transfer Order/Vendor Bill/Vendor Payment numbering - PO-0001, PO-0002, etc.
insert into public."NoSeries" ("SeriesCode", "Description", "Prefix", "Padding", "StartingNo", "WarehouseScoped")
select 'PURCHASE-ORDER', 'Purchase Order No. (Stock On Hand -> Purchase Order)', 'PO-', 4, 1, false
where not exists (select 1 from public."NoSeries" where "SeriesCode" = 'PURCHASE-ORDER');

drop function if exists public.staff_create_purchase_order(text, text, text, text, jsonb);

-- p_lines: JSON array of {item_code, item_name, warehouse_id, warehouse_name, quantity} - matches
-- Stock On Hand's own row shape (js/stockOnHand.js), one line per row that had a non-blank
-- Quantity entered (rows left blank are simply never included - the client filters those out
-- before calling this, but a zero/blank quantity is skipped here too as a safety net).
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

    insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity")
    values (
      v_po_no,
      trim(v_line ->> 'item_code'),
      coalesce(nullif(trim(v_line ->> 'item_name'), ''), trim(v_line ->> 'item_code')),
      nullif(trim(coalesce(v_line ->> 'warehouse_id', '')), ''),
      nullif(trim(coalesce(v_line ->> 'warehouse_name', '')), ''),
      v_quantity
    );
    v_line_count := v_line_count + 1;
  end loop;

  if v_line_count = 0 then
    raise exception 'At least one item with a quantity greater than zero is required.';
  end if;

  return v_po_no;
end;
$$;

grant execute on function public.staff_create_purchase_order(text, text, text, text, jsonb) to anon;

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
      count(l."EntryNo"), coalesce(sum(l."Quantity"), 0),
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

drop function if exists public.staff_get_purchase_order(text, text, text);

create or replace function public.staff_get_purchase_order(p_admin_username text, p_admin_password text, p_po_no text)
returns table(po_no text, vendor_code text, vendor_name text, order_date date, notes text, created_by text, created_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select po."PONo"::text, po."VendorCode"::text, v."Name"::text, po."OrderDate", po."Notes"::text, po."CreatedBy"::text, po."CreatedAtUtc"
    from public."PurchaseOrders" po
    left join public."Vendors" v on v."VendorCode" = po."VendorCode"
    where po."PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_get_purchase_order(text, text, text) to anon;

drop function if exists public.staff_list_purchase_order_lines(text, text, text);

create or replace function public.staff_list_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "EntryNo", "ItemCode"::text, "ItemName"::text, "WarehouseId"::text, "WarehouseName"::text, "Quantity"
    from public."PurchaseOrderLines"
    where "PONo" = p_po_no
    order by "EntryNo";
end;
$$;

grant execute on function public.staff_list_purchase_order_lines(text, text, text) to anon;

drop function if exists public.staff_delete_purchase_order(text, text, text);

-- Deletes the whole PO (header + lines, via the lines' own "on delete cascade") - simple-record
-- scope has no edit UI, so a mistake is corrected by delete-and-recreate rather than in-place
-- editing.
create or replace function public.staff_delete_purchase_order(p_admin_username text, p_admin_password text, p_po_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."PurchaseOrders" where "PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_delete_purchase_order(text, text, text) to anon;
