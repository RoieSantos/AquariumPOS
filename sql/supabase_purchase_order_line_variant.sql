-- Variant on a Purchase Order line - visible and changeable while the order is open, per "now on
-- the PO the item has variant.. can we pull out the variant field while modifying the PO".
--
-- WHAT WAS MISSING. Picking a variant on a New Purchase Order line already did something: the
-- line's ItemCode became the variant's own resolved item code and its ItemName became
-- "Item - Variant" (js/purchaseOrders.js). But WHICH variant that was is recorded nowhere - it
-- survives only as text inside the name. So an existing line could not show its variant as a
-- field, could not preselect it in a picker, and could not have it changed without deleting the
-- line and re-entering it.
--
-- Two columns fix that: "VariantCode" (the Pancake VariationId) and "VariantName". They are the
-- record of what was picked; ItemCode/ItemName keep behaving exactly as they do today, so the
-- receiving path and its Pancake stock-in are untouched by this migration.
--
-- ON PANCAKE STOCK. staff_receive_purchase_order_lines resolves the Pancake variation from the
-- LINE'S ItemCode (supabase_purchase_order_pancake_sync.sql), which is what the variant pick sets
-- - so a variant with its own Items row stocks in against itself. A variant that resolved back to
-- its parent (Variants."ItemCode" falls back to MainItemCode when no SKU match was found) shares
-- the parent's variation id, and stocks in against the parent. That is the behaviour as it stands
-- today and this migration deliberately does not change it: doing so means redefining a 230-line
-- HTTP function to swap one lookup, and it is worth deciding on its own rather than as a side
-- effect of adding a field.

-- ALSO IN THIS FILE, from "in the variant can you flow/validate the description too once its
-- edited" and "for variant can you show the SKU i think that is much detailed description":
-- changing a line's variant now re-derives its Description from the catalog the same way the New
-- Purchase Order grid does (and leaves a hand-typed one alone), and a variant is written SKU-first
-- everywhere it appears. See _po_variant_display_name / _po_line_catalog_description below.

alter table public."PurchaseOrderLines" add column if not exists "VariantCode" varchar(100);
alter table public."PurchaseOrderLines" add column if not exists "VariantName" varchar(255);

alter table public."PostedPurchaseOrderLines" add column if not exists "VariantCode" varchar(100);
alter table public."PostedPurchaseOrderLines" add column if not exists "VariantName" varchar(255);

-- ============================================================================
-- How a variant is written, and how a line's Description is composed from it. Both mirror
-- js/purchaseOrders.js (variantDisplayName / composeLineDescription) exactly, so a variant picked
-- as a line is created and a variant set on an existing line land on the same text.

-- Per "for variant can you show the SKU i think that is much detailed description". The SKU leads
-- because it is the fuller identifier ("A-029-6MM-BLK") beside a bare VariantName ("Black") - but
-- neither is thrown away, and where one already spells the other out (Pancake commonly repeats the
-- variant name inside the SKU) the longer of the two stands alone rather than stuttering.
create or replace function public._po_variant_display_name(p_sku text, p_variant_name text)
returns text
language plpgsql
immutable
as $$
declare
  v_sku text := nullif(trim(coalesce(p_sku, '')), '');
  v_name text := nullif(trim(coalesce(p_variant_name, '')), '');
begin
  if v_sku is null then return v_name; end if;
  if v_name is null then return v_sku; end if;
  -- position(), not LIKE: a SKU is full of characters LIKE treats as wildcards.
  if position(lower(v_name) in lower(v_sku)) > 0 then return v_sku; end if;
  if position(lower(v_sku) in lower(v_name)) > 0 then return v_name; end if;
  return v_sku || ' - ' || v_name;
end;
$$;

-- The catalog text for a line: the item's own Description (what Item Setup edits), falling back to
-- its Name, with the variant appended unless the variant already contains it.
create or replace function public._po_line_catalog_description(p_item_description text, p_item_name text, p_variant_name text)
returns text
language plpgsql
immutable
as $$
declare
  v_base text := coalesce(nullif(trim(coalesce(p_item_description, '')), ''), nullif(trim(coalesce(p_item_name, '')), ''));
  v_variant text := nullif(trim(coalesce(p_variant_name, '')), '');
begin
  if v_variant is null then return v_base; end if;
  if v_base is null then return v_variant; end if;
  if position(lower(v_base) in lower(v_variant)) > 0 then return v_variant; end if;
  return v_base || ' - ' || v_variant;
end;
$$;

-- ============================================================================
-- Changing the variant on an open line.

drop function if exists public.staff_set_purchase_order_line_variant(text, text, bigint, text);

-- p_variation_id null/blank clears the variant and puts the line back on its parent item.
--
-- Blocked once anything has been received, matching the unit-of-measure rule: which variant was
-- ordered is what arrived and was stocked in, and restating it afterwards would misdescribe stock
-- that is already in Pancake.
--
-- THE DESCRIPTION FOLLOWS THE VARIANT, per "in the variant can you flow/validate the description
-- too once its edited" - but only while the Description is still the catalog's own wording. The
-- New Purchase Order grid keeps that distinction in the browser (row.dataset.descriptionAuto: once
-- someone types their own text, changing the item must not throw it away); an existing line has no
-- such flag, so it is inferred instead - a Description that is blank, or that still reads exactly
-- as the catalog would write it for the variant currently on the line, was never hand-edited and
-- is safe to rewrite. Anything else is somebody's own wording and is left alone.
create or replace function public.staff_set_purchase_order_line_variant(
  p_admin_username text,
  p_admin_password text,
  p_entry_no bigint,
  p_variation_id text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line record;
  v_code text := nullif(trim(coalesce(p_variation_id, '')), '');
  v_variant record;
  -- Deliberately a scalar, not a record. A record variable that is never assigned (the line has no
  -- variant yet, or its variant row has since gone) cannot have a field read from it at all -
  -- plpgsql raises "the tuple structure of a not-yet-assigned record is indeterminate" rather than
  -- returning null. SELECT ... INTO a scalar simply leaves it null when nothing matches.
  v_current_main_item_code text;
  v_parent_code text;
  v_parent_name text;
  v_parent_description text;
  v_item_name text;
  v_variant_label text;
  -- What the catalog WOULD have written for the variant the line carries right now. If the stored
  -- Description still matches it, nobody has overtyped it.
  v_current_auto_description text;
  v_description_is_auto boolean;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can edit an existing Purchase Order.';
  end if;

  select * into v_line from public."PurchaseOrderLines" where "EntryNo" = p_entry_no;

  if not found then
    raise exception 'Purchase Order line not found - it may already be posted.';
  end if;

  if coalesce(v_line."QtyReceived", 0) > 0 then
    raise exception 'This line has already been received - its variant can no longer be changed.';
  end if;

  -- The product this line belongs to. Once a variant is on the line its ItemCode is the variant's
  -- resolved code, so the parent has to come from the variant itself; with no variant, the line's
  -- own ItemCode IS the product.
  if v_line."VariantCode" is not null then
    select v."MainItemCode" into v_current_main_item_code
    from public."Variants" v
    where v."VariationId" = v_line."VariantCode";
  end if;

  v_parent_code := coalesce(v_current_main_item_code, v_line."ItemCode");
  select "Name", "Description" into v_parent_name, v_parent_description
  from public."Items" where "Code" = v_parent_code;

  v_current_auto_description := public._po_line_catalog_description(
    v_parent_description, v_parent_name, v_line."VariantName");

  v_description_is_auto :=
    nullif(trim(coalesce(v_line."Description", '')), '') is null
    or trim(v_line."Description") = coalesce(v_current_auto_description, '');

  if v_code is null then
    -- Cleared: back to the plain item, and back to the plain item's description.
    update public."PurchaseOrderLines"
       set "VariantCode" = null,
           "VariantName" = null,
           "ItemCode" = v_parent_code,
           "ItemName" = coalesce(nullif(trim(v_parent_name), ''), v_parent_code),
           "Description" = case
             when v_description_is_auto
               then public._po_line_catalog_description(v_parent_description, v_parent_name, null)
             else "Description"
           end
     where "EntryNo" = p_entry_no;
    return;
  end if;

  select * into v_variant from public."Variants" where "VariationId" = v_code;

  if not found then
    raise exception 'Variant "%" not found.', v_code;
  end if;

  -- A picker only ever offers this product's own variants; this stops a hand-made call from
  -- turning a line for one product into a line for another, which would leave the quantity,
  -- description and cost describing something that is no longer being ordered.
  if coalesce(v_variant."MainItemCode", '') <> v_parent_code
     and coalesce(v_variant."ItemCode", '') <> v_parent_code then
    raise exception 'Variant "%" does not belong to item "%".', v_code, v_parent_code;
  end if;

  -- Same shape the New Purchase Order grid stores: the variant's resolved item code, and a name
  -- reading "Item - Variant" - where "Variant" is now the SKU-led label the pickers show.
  v_variant_label := coalesce(
    public._po_variant_display_name(v_variant."SKU", v_variant."VariantName"),
    v_variant."VariationId");

  v_item_name := concat_ws(' - ',
    nullif(trim(coalesce(v_parent_name, v_parent_code)), ''),
    v_variant_label);

  update public."PurchaseOrderLines"
     set "VariantCode" = v_variant."VariationId",
         "VariantName" = v_variant_label,
         "ItemCode" = coalesce(nullif(trim(v_variant."ItemCode"), ''), v_variant."MainItemCode"),
         "ItemName" = v_item_name,
         "Description" = case
           when v_description_is_auto
             then public._po_line_catalog_description(v_parent_description, v_parent_name, v_variant_label)
           else "Description"
         end
   where "EntryNo" = p_entry_no;
end;
$$;

grant execute on function public.staff_set_purchase_order_line_variant(text, text, bigint, text) to anon;

-- ============================================================================
-- Capturing the variant as a line is created.
--
-- Both functions are the current ones (supabase_units_of_measure.sql) with two fields added, and
-- both are dropped by OID first - they are called through PostgREST by argument name, so an older
-- overload left beside the new one makes every call ambiguous (PGRST203).

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('staff_create_purchase_order', 'staff_add_purchase_order_line')
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
      "UnitOfMeasureCode", "QtyPerUnitOfMeasure", "QuantityUom", "VariantCode", "VariantName"
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
      v_qty_uom,
      nullif(trim(coalesce(v_line ->> 'variant_code', '')), ''),
      nullif(trim(coalesce(v_line ->> 'variant_name', '')), '')
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
  p_quantity_uom numeric default null,
  p_variant_code text default null,
  p_variant_name text default null
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
    "UnitOfMeasureCode", "QtyPerUnitOfMeasure", "QuantityUom", "VariantCode", "VariantName"
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
    p_quantity_uom,
    nullif(trim(coalesce(p_variant_code, '')), ''),
    nullif(trim(coalesce(p_variant_name, '')), '')
  )
  returning "EntryNo" into v_entry_no;

  return v_entry_no;
end;
$$;

grant execute on function public.staff_add_purchase_order_line(text, text, text, text, text, text, text, numeric, text, numeric, text, numeric, numeric, text, text) to anon;

-- ============================================================================
-- The variant follows the order into the posted archive, alongside the ordering unit. Extends the
-- trigger added by supabase_units_of_measure.sql rather than adding a second one - it already
-- matches the live line the posted copy came from, on the values that copy carries.
create or replace function public._posted_purchase_order_line_fill_uom()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new."UnitOfMeasureCode" is null and new."VariantCode" is null then
    select l."UnitOfMeasureCode", l."QtyPerUnitOfMeasure", l."QuantityUom", l."VariantCode", l."VariantName"
      into new."UnitOfMeasureCode", new."QtyPerUnitOfMeasure", new."QuantityUom", new."VariantCode", new."VariantName"
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

-- ============================================================================
-- Line readers return the variant. Bodies are the current ones
-- (supabase_purchase_order_line_uom_edit.sql) with two columns appended - this file supersedes it
-- for both functions.

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

-- Backfill: nothing to do. Lines raised before this migration keep their variant inside ItemName
-- ("Item - Variant"), which is how they already read on every screen; VariantCode stays null and
-- the picker on such a line simply opens on "(No variant)" until one is chosen.

notify pgrst, 'reload schema';

-- Verification. One row per function; create/add must each appear ONCE.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    '_po_variant_display_name',
    '_po_line_catalog_description',
    'staff_set_purchase_order_line_variant',
    'staff_create_purchase_order',
    'staff_add_purchase_order_line',
    'staff_list_purchase_order_lines',
    'staff_list_posted_purchase_order_lines'
  )
order by p.proname, arguments;
