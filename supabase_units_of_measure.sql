-- Units of Measure + conversion, per "can we implement unit of measures and conversion. i think
-- its Item unit of measure in BC". This is Business Central's Unit of Measure (table 204) and Item
-- Unit of Measure (table 5404), adapted to the tables here.
--
-- THE MASTER DATA IS BC'S, EXACTLY:
--
--   public."UnitsOfMeasure"      - the global list of codes (PCS, BOX, KG...). BC table 204.
--   public."ItemUnitsOfMeasure"  - per item, one row per unit it can be handled in, each with
--                                  "QtyPerUnitOfMeasure" - the conversion. BC table 5404.
--   Items."BaseUnitOfMeasure"    - the stock-keeping unit. Always Qty per = 1, by definition.
--   Items."PurchUnitOfMeasure"   - what a Purchase Order line defaults to for this item.
--
-- ONE DELIBERATE DEVIATION, ON THE DOCUMENT LINE. BC stores a line's Quantity in the line's own
-- unit and derives "Quantity (Base)" from it. Here it is the other way round:
-- PurchaseOrderLines."Quantity" and "UnitCost" keep meaning BASE units, exactly as they do today,
-- and three new columns record how the line was ORDERED - the unit, its conversion, and the
-- quantity as typed.
--
-- Why: Quantity in base units is what everything downstream of a PO already consumes, none of
-- which this migration then has to touch or risk -
--   * staff_receive_purchase_order_lines pushes that quantity to Pancake as real stock
--     (supabase_purchase_order_pancake_sync.sql) - Pancake counts in base units;
--   * the posting writeback sets Items."Cost" from the line's UnitCost, and the vendor bill and
--     GL entries are built from Quantity x UnitCost (supabase_gl_posting_integration.sql);
--   * the per-vendor cost trigger (supabase_item_vendors_catalog.sql) reads the same UnitCost;
--   * "Total Qty" on the PO lists sums lines - a sum that only means anything if every line is
--     counted in the same unit.
-- Storing base and remembering the ordering unit keeps every one of those correct with no change,
-- while the screens and the printed PO still read "5 BOX (60 PCS)".
--
-- What that costs: a partial receipt is entered in base units (60, not 5 BOX). The Receive screen
-- shows both, so what to count is never in doubt.

create table if not exists public."UnitsOfMeasure" (
    "Code"        varchar(20) primary key,
    "Description" varchar(100)
);

alter table public."UnitsOfMeasure" enable row level security;
revoke all on public."UnitsOfMeasure" from anon, authenticated;

-- A starting list. Codes are free-form - adding an item unit in Item Setup creates any code that
-- is not here yet, so this only has to cover the common ones rather than every case.
insert into public."UnitsOfMeasure" ("Code", "Description")
values
  ('PCS', 'Piece'),
  ('BOX', 'Box'),
  ('CTN', 'Carton'),
  ('PACK', 'Pack'),
  ('SET', 'Set'),
  ('PAIR', 'Pair'),
  ('DOZ', 'Dozen'),
  ('BAG', 'Bag'),
  ('BOTTLE', 'Bottle'),
  ('ROLL', 'Roll'),
  ('SHEET', 'Sheet'),
  ('KG', 'Kilogram'),
  ('G', 'Gram'),
  ('L', 'Litre'),
  ('ML', 'Millilitre'),
  ('M', 'Metre'),
  ('CM', 'Centimetre'),
  ('FT', 'Foot')
on conflict ("Code") do nothing;

-- BC table 5404. QtyPerUnitOfMeasure is the conversion INTO base units: BOX with 12 means one box
-- is twelve of the item's base unit.
create table if not exists public."ItemUnitsOfMeasure" (
    "ItemCode"            varchar(200) not null references public."Items"("Code") on delete cascade,
    "UnitOfMeasureCode"   varchar(20)  not null references public."UnitsOfMeasure"("Code"),
    "QtyPerUnitOfMeasure" numeric(18, 4) not null default 1,
    primary key ("ItemCode", "UnitOfMeasureCode"),
    constraint "CK_ItemUnitsOfMeasure_QtyPositive" check ("QtyPerUnitOfMeasure" > 0)
);

create index if not exists "IX_ItemUnitsOfMeasure_UnitOfMeasureCode" on public."ItemUnitsOfMeasure" ("UnitOfMeasureCode");

alter table public."ItemUnitsOfMeasure" enable row level security;
revoke all on public."ItemUnitsOfMeasure" from anon, authenticated;

-- Base = how stock is counted (Pancake's own quantities, Items."QuantityInStock"), so every
-- existing item starts on PCS: that is what its stock figures already mean.
alter table public."Items" add column if not exists "BaseUnitOfMeasure" varchar(20);
alter table public."Items" add column if not exists "PurchUnitOfMeasure" varchar(20);

update public."Items" set "BaseUnitOfMeasure" = 'PCS' where "BaseUnitOfMeasure" is null;

-- Every item gets its base unit as a row, at the by-definition conversion of 1.
insert into public."ItemUnitsOfMeasure" ("ItemCode", "UnitOfMeasureCode", "QtyPerUnitOfMeasure")
select i."Code", i."BaseUnitOfMeasure", 1
from public."Items" i
where i."BaseUnitOfMeasure" is not null
on conflict ("ItemCode", "UnitOfMeasureCode") do nothing;

-- How the line was ordered. Quantity/UnitCost beside these stay in BASE units - see the header.
alter table public."PurchaseOrderLines" add column if not exists "UnitOfMeasureCode" varchar(20);
alter table public."PurchaseOrderLines" add column if not exists "QtyPerUnitOfMeasure" numeric(18, 4);
alter table public."PurchaseOrderLines" add column if not exists "QuantityUom" numeric(18, 2);

alter table public."PostedPurchaseOrderLines" add column if not exists "UnitOfMeasureCode" varchar(20);
alter table public."PostedPurchaseOrderLines" add column if not exists "QtyPerUnitOfMeasure" numeric(18, 4);
alter table public."PostedPurchaseOrderLines" add column if not exists "QuantityUom" numeric(18, 2);

-- ============================================================================
-- Master data maintenance (Item Setup factbox).

drop function if exists public.staff_list_units_of_measure(text, text);

create or replace function public.staff_list_units_of_measure(p_admin_username text, p_admin_password text)
returns table(code text, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select u."Code"::text, u."Description"::text
    from public."UnitsOfMeasure" u
    order by u."Code";
end;
$$;

grant execute on function public.staff_list_units_of_measure(text, text) to anon;

drop function if exists public.staff_list_item_units_of_measure(text, text, text);

-- Staff-level, not super-user: the Purchase Order screens read this to fill a line's unit picker.
create or replace function public.staff_list_item_units_of_measure(p_admin_username text, p_admin_password text, p_item_code text)
returns table(unit_of_measure_code text, description text, qty_per_unit_of_measure numeric, is_base boolean, is_purch boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- is_base/is_purch are derived from the Items row rather than stored twice, so "which is the
  -- base unit" has exactly one answer. Base sorts first, then the rest alphabetically.
  return query
    select iu."UnitOfMeasureCode"::text, u."Description"::text, iu."QtyPerUnitOfMeasure",
           (i."BaseUnitOfMeasure" = iu."UnitOfMeasureCode") as is_base,
           (i."PurchUnitOfMeasure" = iu."UnitOfMeasureCode") as is_purch
    from public."ItemUnitsOfMeasure" iu
    join public."Items" i on i."Code" = iu."ItemCode"
    left join public."UnitsOfMeasure" u on u."Code" = iu."UnitOfMeasureCode"
    where iu."ItemCode" = p_item_code
    order by (i."BaseUnitOfMeasure" = iu."UnitOfMeasureCode") desc, iu."UnitOfMeasureCode";
end;
$$;

grant execute on function public.staff_list_item_units_of_measure(text, text, text) to anon;

drop function if exists public.admin_upsert_item_unit_of_measure(text, text, text, text, numeric, text);

create or replace function public.admin_upsert_item_unit_of_measure(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_unit_of_measure_code text,
  p_qty_per_unit_of_measure numeric,
  p_description text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(nullif(trim(coalesce(p_unit_of_measure_code, '')), ''));
  v_base text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_code is null then
    raise exception 'A unit of measure code is required.';
  end if;

  if p_qty_per_unit_of_measure is null or p_qty_per_unit_of_measure <= 0 then
    raise exception 'Qty per Unit of Measure must be greater than 0.';
  end if;

  select "BaseUnitOfMeasure" into v_base from public."Items" where "Code" = p_item_code;

  if not found then
    raise exception 'Item "%" not found.', p_item_code;
  end if;

  -- The base unit is the ruler everything else is measured against - one of it is one of it.
  if v_base = v_code and p_qty_per_unit_of_measure <> 1 then
    raise exception 'The base unit (%) always has a Qty per Unit of Measure of 1.', v_base;
  end if;

  -- A code that is not in the master list yet is added rather than rejected - there is no
  -- separate Unit of Measure Setup page, and stopping to create one first would be busywork.
  insert into public."UnitsOfMeasure" ("Code", "Description")
  values (v_code, nullif(trim(coalesce(p_description, '')), ''))
  on conflict ("Code") do nothing;

  insert into public."ItemUnitsOfMeasure" ("ItemCode", "UnitOfMeasureCode", "QtyPerUnitOfMeasure")
  values (p_item_code, v_code, p_qty_per_unit_of_measure)
  on conflict ("ItemCode", "UnitOfMeasureCode") do update
    set "QtyPerUnitOfMeasure" = excluded."QtyPerUnitOfMeasure";
end;
$$;

grant execute on function public.admin_upsert_item_unit_of_measure(text, text, text, text, numeric, text) to anon;

drop function if exists public.admin_remove_item_unit_of_measure(text, text, text, text);

create or replace function public.admin_remove_item_unit_of_measure(p_admin_username text, p_admin_password text, p_item_code text, p_unit_of_measure_code text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Removing either of these would leave the item pointing at a unit it no longer has a
  -- conversion for, and every quantity on it unreadable.
  if exists (
    select 1 from public."Items"
    where "Code" = p_item_code
      and (coalesce("BaseUnitOfMeasure", '') = p_unit_of_measure_code
        or coalesce("PurchUnitOfMeasure", '') = p_unit_of_measure_code)
  ) then
    raise exception 'This is the item''s base or purchase unit. Change those first.';
  end if;

  delete from public."ItemUnitsOfMeasure"
  where "ItemCode" = p_item_code and "UnitOfMeasureCode" = p_unit_of_measure_code;
end;
$$;

grant execute on function public.admin_remove_item_unit_of_measure(text, text, text, text) to anon;

drop function if exists public.admin_set_item_units_of_measure(text, text, text, text, text);

-- Sets the item's base and purchase units together, since they constrain each other.
--
-- Changing the BASE unit does not restate existing stock or costs - Items."QuantityInStock" comes
-- from Pancake and Items."Cost" is per base unit, so a base change silently redefines what both of
-- those numbers mean. It is therefore only allowed while the item has no other units defined,
-- which in practice means before it has been used - exactly BC's own rule (it blocks the change
-- once there are entries).
create or replace function public.admin_set_item_units_of_measure(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_base_unit_of_measure text,
  p_purch_unit_of_measure text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base text := upper(nullif(trim(coalesce(p_base_unit_of_measure, '')), ''));
  v_purch text := upper(nullif(trim(coalesce(p_purch_unit_of_measure, '')), ''));
  v_current_base text;
  v_other_units int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_base is null then
    raise exception 'A base unit of measure is required.';
  end if;

  select "BaseUnitOfMeasure" into v_current_base from public."Items" where "Code" = p_item_code;

  if not found then
    raise exception 'Item "%" not found.', p_item_code;
  end if;

  if v_current_base is distinct from v_base then
    select count(*) into v_other_units
    from public."ItemUnitsOfMeasure"
    where "ItemCode" = p_item_code and "UnitOfMeasureCode" <> coalesce(v_current_base, '');

    if v_other_units > 0 then
      raise exception 'Remove the item''s other units of measure before changing its base unit - their conversions are all relative to it.';
    end if;

    -- The old base row is no longer meaningful once the ruler changes.
    delete from public."ItemUnitsOfMeasure"
    where "ItemCode" = p_item_code and "UnitOfMeasureCode" = coalesce(v_current_base, '');
  end if;

  insert into public."UnitsOfMeasure" ("Code") values (v_base) on conflict ("Code") do nothing;

  insert into public."ItemUnitsOfMeasure" ("ItemCode", "UnitOfMeasureCode", "QtyPerUnitOfMeasure")
  values (p_item_code, v_base, 1)
  on conflict ("ItemCode", "UnitOfMeasureCode") do update set "QtyPerUnitOfMeasure" = 1;

  -- The purchase unit has to be one the item actually has a conversion for, or a PO line could
  -- not work out what it is ordering.
  if v_purch is not null and not exists (
    select 1 from public."ItemUnitsOfMeasure"
    where "ItemCode" = p_item_code and "UnitOfMeasureCode" = v_purch
  ) then
    raise exception 'Add "%" to this item''s units of measure before making it the purchase unit.', v_purch;
  end if;

  update public."Items"
     set "BaseUnitOfMeasure" = v_base,
         "PurchUnitOfMeasure" = v_purch
   where "Code" = p_item_code;
end;
$$;

grant execute on function public.admin_set_item_units_of_measure(text, text, text, text, text) to anon;

-- ============================================================================
-- Purchase Order lines carry the ordering unit.

-- staff_create_purchase_order: p_lines gains optional per-line "uom_code", "qty_per_uom" and
-- "quantity_uom" keys. When quantity_uom is present the stored (base) Quantity is computed from
-- it here rather than in the browser, so the conversion has one home.
--
-- Dropped by OID - see supabase_purchase_order_header_warehouse.sql for why a signature-specific
-- drop is not enough for a PostgREST-called function.
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
  v_uom_code text;
  v_qty_per numeric;
  v_qty_uom numeric;
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

  if v_warehouse_id is not null and not exists (select 1 from public."Warehouses" where "ID" = v_warehouse_id) then
    raise exception 'Warehouse "%" not found.', v_warehouse_id;
  end if;

  v_po_no := public._next_no_series_number('PURCHASE-ORDER', '');

  insert into public."PurchaseOrders" ("PONo", "VendorCode", "Notes", "CreatedBy", "WarehouseId", "WarehouseName")
  values (v_po_no, v_vendor_code, nullif(trim(coalesce(p_notes, '')), ''), p_admin_username, v_warehouse_id, v_warehouse_name);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_uom_code := nullif(trim(coalesce(v_line ->> 'uom_code', '')), '');
    v_qty_per := nullif(trim(coalesce(v_line ->> 'qty_per_uom', '')), '')::numeric;
    v_qty_uom := nullif(trim(coalesce(v_line ->> 'quantity_uom', '')), '')::numeric;

    if v_qty_per is not null and v_qty_per <= 0 then
      raise exception 'Qty per Unit of Measure must be greater than 0.';
    end if;

    -- Ordered in a unit: the base quantity IS the conversion. Ordered without one (Stock On Hand,
    -- which works in base units): the quantity as given.
    if v_qty_uom is not null then
      v_quantity := v_qty_uom * coalesce(v_qty_per, 1);
    else
      v_quantity := (v_line ->> 'quantity')::numeric;
    end if;

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

    insert into public."PurchaseOrderLines" (
      "PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "Description", "UnitCost",
      "UnitOfMeasureCode", "QtyPerUnitOfMeasure", "QuantityUom"
    )
    values (
      v_po_no,
      v_item_code,
      coalesce(nullif(trim(v_line ->> 'item_name'), ''), v_item_code),
      coalesce(nullif(trim(coalesce(v_line ->> 'warehouse_id', '')), ''), v_warehouse_id),
      coalesce(nullif(trim(coalesce(v_line ->> 'warehouse_name', '')), ''), v_warehouse_name),
      v_quantity,
      nullif(trim(coalesce(v_line ->> 'description', '')), ''),
      v_unit_cost,
      v_uom_code,
      v_qty_per,
      v_qty_uom
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

-- staff_add_purchase_order_line: same three optional fields, same conversion rule. p_quantity is
-- still the BASE quantity when no unit is given.
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'staff_add_purchase_order_line'
  loop
    raise notice 'Dropping overload: %', r.signature;
    execute format('drop function %s', r.signature);
  end loop;
end;
$$;

create or replace function public.staff_add_purchase_order_line(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_item_code text,
  p_item_name text,
  p_warehouse_id text,
  p_warehouse_name text,
  p_quantity numeric,
  p_description text default null,
  p_unit_cost numeric default null,
  p_uom_code text default null,
  p_qty_per_uom numeric default null,
  p_quantity_uom numeric default null
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry_no bigint;
  v_unit_cost numeric := p_unit_cost;
  v_uom_code text := nullif(trim(coalesce(p_uom_code, '')), '');
  v_quantity numeric;
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

  if p_qty_per_uom is not null and p_qty_per_uom <= 0 then
    raise exception 'Qty per Unit of Measure must be greater than 0.';
  end if;

  if p_quantity_uom is not null then
    v_quantity := p_quantity_uom * coalesce(p_qty_per_uom, 1);
  else
    v_quantity := p_quantity;
  end if;

  if v_quantity is null or v_quantity <= 0 then
    raise exception 'Quantity must be greater than 0.';
  end if;

  if v_unit_cost is null then
    select i."Cost" into v_unit_cost from public."Items" i where i."Code" = trim(p_item_code);
  end if;

  if v_unit_cost is not null and v_unit_cost < 0 then
    raise exception 'Unit cost cannot be negative.';
  end if;

  insert into public."PurchaseOrderLines" (
    "PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "Description", "UnitCost",
    "UnitOfMeasureCode", "QtyPerUnitOfMeasure", "QuantityUom"
  )
  values (
    p_po_no,
    trim(p_item_code),
    coalesce(nullif(trim(p_item_name), ''), trim(p_item_code)),
    nullif(trim(coalesce(p_warehouse_id, '')), ''),
    nullif(trim(coalesce(p_warehouse_name, '')), ''),
    v_quantity,
    nullif(trim(coalesce(p_description, '')), ''),
    v_unit_cost,
    v_uom_code,
    p_qty_per_uom,
    p_quantity_uom
  )
  returning "EntryNo" into v_entry_no;

  return v_entry_no;
end;
$$;

grant execute on function public.staff_add_purchase_order_line(text, text, text, text, text, text, text, numeric, text, numeric, text, numeric, numeric) to anon;

-- ============================================================================
-- The ordering unit follows the order into the posted archive.
--
-- A trigger, not an edit to staff_post_purchase_order's INSERT - that function is redefined by
-- several migrations and the newest lives in the GL integration file, so a column added to its
-- body would be lost the next time one of those is re-run (same reasoning as the header-warehouse
-- carry-over in supabase_purchase_order_header_warehouse.sql).
--
-- The posted line gets a fresh EntryNo, so the live line it came from is matched on the values the
-- copy carries: PO, item, warehouse, quantity and cost. Where a PO has two lines that agree on all
-- five, they are interchangeable for this purpose - the unit copied is right either way.
create or replace function public._posted_purchase_order_line_fill_uom()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new."UnitOfMeasureCode" is null then
    select l."UnitOfMeasureCode", l."QtyPerUnitOfMeasure", l."QuantityUom"
      into new."UnitOfMeasureCode", new."QtyPerUnitOfMeasure", new."QuantityUom"
    from public."PurchaseOrderLines" l
    where l."PONo" = new."PONo"
      and l."ItemCode" = new."ItemCode"
      and coalesce(l."WarehouseId", '') = coalesce(new."WarehouseId", '')
      and l."Quantity" = new."Quantity"
      and coalesce(l."UnitCost", -1) = coalesce(new."UnitCost", -1)
    limit 1;
  end if;

  return new;
end;
$$;

drop trigger if exists "TR_PostedPurchaseOrderLines_FillUom" on public."PostedPurchaseOrderLines";
create trigger "TR_PostedPurchaseOrderLines_FillUom"
before insert on public."PostedPurchaseOrderLines"
for each row execute function public._posted_purchase_order_line_fill_uom();

-- ============================================================================
-- Line readers gain the ordering unit. Bodies are the current ones (line costing from
-- supabase_item_cost_and_po_line_cost.sql, vendor item no. from
-- supabase_item_vendors_catalog.sql) with the three unit columns appended - this file supersedes
-- both for these two functions.

drop function if exists public.staff_list_purchase_order_lines(text, text, text);

create or replace function public.staff_list_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric, vendor_item_no text, uom_code text, qty_per_uom numeric, quantity_uom numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."EntryNo", l."ItemCode"::text, l."ItemName"::text, l."WarehouseId"::text, l."WarehouseName"::text,
           l."Quantity", l."QtyReceived", l."Description"::text, l."UnitCost",
           round(coalesce(l."UnitCost", 0) * l."Quantity", 2),
           iv."VendorItemNo"::text,
           l."UnitOfMeasureCode"::text, l."QtyPerUnitOfMeasure", l."QuantityUom"
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
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric, vendor_item_no text, uom_code text, qty_per_uom numeric, quantity_uom numeric)
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
           l."UnitOfMeasureCode"::text, l."QtyPerUnitOfMeasure", l."QuantityUom"
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

-- ============================================================================
-- Verification.

-- One row per function. staff_create_purchase_order and staff_add_purchase_order_line must each
-- appear ONCE - more than one and PostgREST cannot choose between them (PGRST203).
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'staff_list_units_of_measure',
    'staff_list_item_units_of_measure',
    'admin_upsert_item_unit_of_measure',
    'admin_remove_item_unit_of_measure',
    'admin_set_item_units_of_measure',
    'staff_create_purchase_order',
    'staff_add_purchase_order_line',
    'staff_list_purchase_order_lines',
    'staff_list_posted_purchase_order_lines'
  )
order by p.proname, arguments;

-- Every item should now have a base unit and one ItemUnitsOfMeasure row for it. items_with_extra_
-- units stays 0 until you start adding boxes/cartons in Item Setup.
select
  (select count(*) from public."Items") as items,
  (select count(*) from public."Items" where "BaseUnitOfMeasure" is not null) as items_with_base_unit,
  (select count(*) from public."ItemUnitsOfMeasure") as item_unit_rows,
  (select count(*) from (
     select "ItemCode" from public."ItemUnitsOfMeasure" group by "ItemCode" having count(*) > 1
   ) as m) as items_with_extra_units;
