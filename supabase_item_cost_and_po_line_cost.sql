-- Item cost tracking + Purchase Order line cost - per direct request: "in the items can we add
-- cost per item? this will help us track the cost and also auto compute cost on what we are
-- ordering".
--
-- Items."Cost" ALREADY EXISTS (supabase_warehouses_items_tables.sql) and admin_list_items already
-- returns it - it simply had no way to be edited and nothing consuming it. Critically, the Pancake
-- sync never writes it: neither the UPDATE nor the upsert in supabase_pancake_manual_sync.sql
-- touches "Cost" (Pancake is a selling platform and has no concept of cost), so a cost typed in
-- here survives every sync. That makes Items."Cost" portal-owned in practice, the same way
-- HideFromSet and the Vendors link are.
--
-- What this file adds:
--   1. admin_set_item_cost - the missing setter, mirroring admin_set_item_hide_from_set exactly
--      (super-user gate, single column update).
--   2. "UnitCost" on PurchaseOrderLines and its posted-archive twin PostedPurchaseOrderLines, so a
--      PO can total what it is going to cost. Widened exactly the way "Description" was added in
--      supabase_purchase_order_line_description.sql - that file is the direct template here, and
--      the function bodies below are its versions plus UnitCost.
--   3. Last-cost writeback on posting: a posted PO pushes the unit cost actually paid back onto
--      Items."Cost", so the catalog cost maintains itself instead of going stale.
--
-- Same Postgres 42P13 convention as the description file: functions whose RETURN TABLE shape
-- changes need an explicit drop first; ones that only widen a jsonb payload or gain a defaulted
-- parameter keep "create or replace".

alter table public."PurchaseOrderLines" add column if not exists "UnitCost" numeric(18, 4);
alter table public."PostedPurchaseOrderLines" add column if not exists "UnitCost" numeric(18, 4);

-- Sets the catalog cost for one item. Super-user gated (is_admin_authorized), matching its
-- sibling setters admin_set_item_vendor / admin_set_item_hide_from_set on the same Item Setup
-- page rather than the looser is_staff_authorized the Purchase Order RPCs use.
--
-- A null/blank cost is stored as NULL rather than 0 - "not costed yet" and "costs nothing" are
-- different things, and only NULL should make a PO line fall back to asking the user.
create or replace function public.admin_set_item_cost(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_cost numeric
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

  if p_cost is not null and p_cost < 0 then
    raise exception 'Cost cannot be negative.';
  end if;

  update public."Items" set "Cost" = p_cost where "Code" = p_item_code;
end;
$$;

grant execute on function public.admin_set_item_cost(text, text, text, numeric) to anon;

-- Bulk cost import for Item Setup's Export/Import Excel round-trip - per "if I export / import
-- excel will that also include cost fields?". Mirrors admin_bulk_set_item_vendors
-- (supabase_item_bulk_set_vendor.sql) exactly: same jsonb-array shape, same
-- updated/skipped/errors return so the import can report per-row problems instead of failing
-- wholesale.
--
-- The caller only includes a row here when the imported file actually HAS a Cost column - a file
-- without one must leave costs untouched, otherwise a trimmed-down re-import (Item Code only, to
-- fix vendors) would silently wipe the cost off every item it mentions. Within a file that does
-- carry the column, a blank cell is a deliberate "clear this cost" and stores NULL, which is
-- distinct from a cost of 0.
create or replace function public.admin_bulk_set_item_costs(
  p_admin_username text,
  p_admin_password text,
  p_items jsonb
)
returns table(updated_count int, skipped_count int, errors text[])
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row jsonb;
  v_item_code text;
  v_cost_text text;
  v_cost numeric;
  v_invalid boolean;
  v_updated int := 0;
  v_skipped int := 0;
  v_errors text[] := array[]::text[];
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'p_items must be a JSON array.';
  end if;

  for v_row in select * from jsonb_array_elements(p_items)
  loop
    v_item_code := trim(coalesce(v_row ->> 'item_code', ''));
    v_cost_text := nullif(trim(coalesce(v_row ->> 'cost', '')), '');

    if v_item_code = '' then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || 'Skipped a row with no Item Code.';
      continue;
    end if;

    if not exists (select 1 from public."Items" where "Code" = v_item_code) then
      v_skipped := v_skipped + 1;
      v_errors := v_errors || (v_item_code || ': item not found - skipped.');
      continue;
    end if;

    -- A spreadsheet cell can hold anything ("N/A", "1,200", "P450"). Reject it by name rather
    -- than letting one bad cast abort the whole import.
    --
    -- The failure is recorded on a flag and acted on AFTER the nested block rather than jumping
    -- straight out with CONTINUE from inside the exception handler - clearer, and it avoids
    -- relying on control transfer out of an exception handler behaving the same across versions.
    v_cost := null;
    v_invalid := false;

    if v_cost_text is not null then
      begin
        v_cost := v_cost_text::numeric;
      exception when others then
        v_invalid := true;
        v_errors := v_errors || (v_item_code || ': "' || v_cost_text || '" is not a valid cost - skipped.');
      end;

      if not v_invalid and v_cost < 0 then
        v_invalid := true;
        v_errors := v_errors || (v_item_code || ': cost cannot be negative - skipped.');
      end if;
    end if;

    if v_invalid then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    update public."Items" set "Cost" = v_cost where "Code" = v_item_code;
    v_updated := v_updated + 1;
  end loop;

  return query select v_updated, v_skipped, v_errors;
end;
$$;

grant execute on function public.admin_bulk_set_item_costs(text, text, jsonb) to anon;

-- staff_search_items: gains a trailing "cost" column so the New Purchase Order item picker can
-- prefill a line's unit cost the moment an item is chosen - that prefill is what makes the PO
-- total compute itself instead of being typed in.
--
-- Return table shape changes, so the explicit drop is required (Postgres 42P13). Signature and
-- parameter defaults are unchanged, and the new column is appended last, so the other caller
-- (Transfer Orders' item picker in transferOrders.js) keeps working untouched - it just ignores
-- the extra field.
drop function if exists public.staff_search_items(text, text, text, int, boolean, int, text);

create or replace function public.staff_search_items(p_admin_username text, p_admin_password text, p_search text default null, p_limit int default 20, p_use_production_category boolean default null, p_page int default 1, p_vendor_code text default null)
returns table(code text, name text, category_code text, quantity_in_stock int, total_count bigint, cost numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."Code"::text, i."Name"::text, i."CategoryCode"::text, i."QuantityInStock",
           count(*) over(), i."Cost"
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where (p_search is null or trim(p_search) = '' or i."Code" ilike '%' || p_search || '%' or i."Name" ilike '%' || p_search || '%')
      and (p_use_production_category is null or coalesce(c."IsProductionCategory", false) = p_use_production_category)
      and not coalesce(c."ExcludeInTransferOrders", false)
      and (p_vendor_code is null or trim(p_vendor_code) = '' or i."VendorCode" = p_vendor_code)
    order by i."Name"
    limit v_limit offset (v_page - 1) * v_limit;
end;
$$;

grant execute on function public.staff_search_items(text, text, text, int, boolean, int, text) to anon;

-- staff_create_purchase_order: p_lines gains an optional "unit_cost" key per line (same jsonb
-- param, no signature change - no drop needed).
--
-- A line that omits unit_cost falls back to the item's current catalog cost, which is what makes
-- the PO total compute itself from the item list. The value is then SNAPSHOT onto the line: a PO
-- is a point-in-time record (same reasoning as the denormalized ItemName/WarehouseName), so
-- re-costing an item later must not silently rewrite what an existing order says it will cost.
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

    v_item_code := trim(v_line ->> 'item_code');
    v_unit_cost := nullif(trim(coalesce(v_line ->> 'unit_cost', '')), '')::numeric;

    if v_unit_cost is null then
      select i."Cost" into v_unit_cost from public."Items" i where i."Code" = v_item_code;
    end if;

    if v_unit_cost is not null and v_unit_cost < 0 then
      raise exception 'Unit cost cannot be negative (item "%").', v_item_code;
    end if;

    insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "Description", "UnitCost")
    values (
      v_po_no,
      v_item_code,
      coalesce(nullif(trim(v_line ->> 'item_name'), ''), v_item_code),
      nullif(trim(coalesce(v_line ->> 'warehouse_id', '')), ''),
      nullif(trim(coalesce(v_line ->> 'warehouse_name', '')), ''),
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

drop function if exists public.staff_add_purchase_order_line(text, text, text, text, text, text, text, numeric, text);

-- Same catalog-cost fallback as the create path above, so a line added to an existing PO costs
-- the same way as one created with it.
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
  p_unit_cost numeric default null
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry_no bigint;
  v_unit_cost numeric := p_unit_cost;
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

  if v_unit_cost is null then
    select i."Cost" into v_unit_cost from public."Items" i where i."Code" = trim(p_item_code);
  end if;

  if v_unit_cost is not null and v_unit_cost < 0 then
    raise exception 'Unit cost cannot be negative.';
  end if;

  insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "Description", "UnitCost")
  values (
    p_po_no,
    trim(p_item_code),
    coalesce(nullif(trim(p_item_name), ''), trim(p_item_code)),
    nullif(trim(coalesce(p_warehouse_id, '')), ''),
    nullif(trim(coalesce(p_warehouse_name, '')), ''),
    p_quantity,
    nullif(trim(coalesce(p_description, '')), ''),
    v_unit_cost
  )
  returning "EntryNo" into v_entry_no;

  return v_entry_no;
end;
$$;

grant execute on function public.staff_add_purchase_order_line(text, text, text, text, text, text, text, numeric, text, numeric) to anon;

-- Lets a super user re-cost a line already on an open PO (a vendor quotes differently than the
-- catalog said). Deliberately blocked once anything has been received against the line, matching
-- staff_remove_purchase_order_line's reasoning: that quantity was already stocked in at the cost
-- shown, so changing it after the fact would rewrite history.
create or replace function public.staff_set_purchase_order_line_cost(
  p_admin_username text,
  p_admin_password text,
  p_entry_no bigint,
  p_unit_cost numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_qty_received numeric;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can edit an existing Purchase Order.';
  end if;

  select "QtyReceived" into v_qty_received
  from public."PurchaseOrderLines"
  where "EntryNo" = p_entry_no;

  if not found then
    raise exception 'Purchase Order line not found - it may already be posted.';
  end if;

  if coalesce(v_qty_received, 0) > 0 then
    raise exception 'This line has already been received - its cost can no longer be changed.';
  end if;

  if p_unit_cost is not null and p_unit_cost < 0 then
    raise exception 'Unit cost cannot be negative.';
  end if;

  update public."PurchaseOrderLines" set "UnitCost" = p_unit_cost where "EntryNo" = p_entry_no;
end;
$$;

grant execute on function public.staff_set_purchase_order_line_cost(text, text, bigint, numeric) to anon;

-- Editable line Description on an open PO - per direct request: "make the description editable so
-- they can manually fill in the text and able to print it out". Until now Description could only
-- be set when the line was first added; this lets it be filled in or corrected while the PO is
-- being worked, and purchase-order-print.html already prints the column.
--
-- Two deliberate differences from staff_set_purchase_order_line_cost above:
--
--   NOT blocked once received. Cost is blocked after receipt because that quantity was already
--   stocked in at that cost and changing it would rewrite financial history. A description carries
--   no such meaning - it is a note for whoever handles the goods, and it is often only AFTER a
--   delivery arrives that there is something worth noting. Blocking it would defeat the request.
--
--   is_staff_authorized, not is_admin_authorized. Adding or removing a line is structural and
--   stays super-user only (supabase_purchase_order_edit_lines.sql); typing a note is neither
--   structural nor financial, and the ask was explicitly that staff can fill it in themselves.
--   Tighten this to is_admin_authorized if that turns out to be too open.
--
-- Only ever reaches PurchaseOrderLines, so a posted PO's archived record cannot be edited - the
-- EntryNo lookup simply fails, same as the other line editors.
create or replace function public.staff_set_purchase_order_line_description(
  p_admin_username text,
  p_admin_password text,
  p_entry_no bigint,
  p_description text
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

  if not exists (select 1 from public."PurchaseOrderLines" where "EntryNo" = p_entry_no) then
    raise exception 'Purchase Order line not found - it may already be posted.';
  end if;

  -- Matches the column width so an over-long paste fails loudly here rather than being silently
  -- truncated by the database.
  if length(coalesce(p_description, '')) > 500 then
    raise exception 'Description cannot be longer than 500 characters.';
  end if;

  update public."PurchaseOrderLines"
     set "Description" = nullif(trim(coalesce(p_description, '')), '')
   where "EntryNo" = p_entry_no;
end;
$$;

grant execute on function public.staff_set_purchase_order_line_description(text, text, bigint, text) to anon;

drop function if exists public.staff_list_purchase_order_lines(text, text, text);

create or replace function public.staff_list_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric)
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
    select "EntryNo", "ItemCode"::text, "ItemName"::text, "WarehouseId"::text, "WarehouseName"::text,
           "Quantity", "QtyReceived", "Description"::text, "UnitCost",
           round(coalesce("UnitCost", 0) * "Quantity", 2)
    from public."PurchaseOrderLines"
    where "PONo" = p_po_no
    order by "EntryNo";
end;
$$;

grant execute on function public.staff_list_purchase_order_lines(text, text, text) to anon;

drop function if exists public.staff_list_posted_purchase_order_lines(text, text, text);

create or replace function public.staff_list_posted_purchase_order_lines(p_admin_username text, p_admin_password text, p_po_no text)
returns table(entry_no bigint, item_code text, item_name text, warehouse_id text, warehouse_name text, quantity numeric, qty_received numeric, description text, unit_cost numeric, line_cost numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Posted lines cost out against what was actually RECEIVED, not what was ordered - the archive
  -- is a record of money committed, and a short-shipped line did not cost the full ordered
  -- quantity. Open POs above use Quantity instead, since nothing has arrived yet.
  return query
    select "EntryNo", "ItemCode"::text, "ItemName"::text, "WarehouseId"::text, "WarehouseName"::text,
           "Quantity", "QtyReceived", "Description"::text, "UnitCost",
           round(coalesce("UnitCost", 0) * coalesce("QtyReceived", 0), 2)
    from public."PostedPurchaseOrderLines"
    where "PONo" = p_po_no
    order by "EntryNo";
end;
$$;

grant execute on function public.staff_list_posted_purchase_order_lines(text, text, text) to anon;

-- staff_post_purchase_order: carries UnitCost into the archive, then applies the LAST-COST
-- writeback (chosen over weighted-average per direct decision) - Items."Cost" becomes the unit
-- cost actually paid on this PO.
--
-- Only lines that were actually received update the catalog: an ordered-but-never-delivered line
-- never cost anything, so letting it set the catalog cost would record a price that was never
-- paid. Where the same item appears on several lines of one PO (different warehouses), the
-- highest EntryNo wins - that is the most recently entered cost for it.
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

  insert into public."PostedPurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived", "Description", "UnitCost")
  select "PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived", "Description", "UnitCost"
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no;

  update public."Items" i
     set "Cost" = latest."UnitCost"
    from (
      select distinct on ("ItemCode") "ItemCode", "UnitCost"
      from public."PurchaseOrderLines"
      where "PONo" = p_po_no
        and "UnitCost" is not null
        and coalesce("QtyReceived", 0) > 0
      order by "ItemCode", "EntryNo" desc
    ) as latest
   where i."Code" = latest."ItemCode";

  delete from public."PurchaseOrders" where "PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_post_purchase_order(text, text, text) to anon;

-- Dashboard "Total Purchase" card - finally wireable now that PO lines carry a cost. The card
-- (dashboard.html) has stood as a "Coming soon / Formula to be added" placeholder precisely
-- because PurchaseOrderLines had only a Quantity, so there was no figure to total.
--
-- Deliberately mirrors admin_get_expense_entry_summary (supabase_expense_entry_tables.sql), which
-- the dashboard comment names as the template - same is_admin_authorized gate, same optional
-- warehouse scoping, and the same Asia/Manila month boundary so the Purchase and Expense cards
-- can never disagree about what "this month" means regardless of the viewer's own timezone.
--
-- Three deliberate choices in the formula:
--   POSTED ONLY. An open PO is an intention, not money spent, and it can still be edited. This
--   matches the Expense card counting only posted expenses.
--
--   COSTED AGAINST QtyReceived, not Quantity - a short-shipped line did not cost the full ordered
--   amount. Same basis staff_list_posted_purchase_order_lines already uses for its line_cost.
--
--   DATED BY OrderDate, not PostedAtUtc. This is the one place it departs from a literal reading
--   of "posted": OrderDate is the PO's business date, the direct equivalent of an expense's own
--   "Date". Keying off the posting timestamp instead would drop a January order into March's
--   purchases just because nobody got round to posting it.
--
-- month_uncosted_po_count exists so the dashboard can say WHY a total looks low: any line that
-- was received but never costed contributes zero, and without this the card would silently
-- understate purchases while the catalog is still being costed up.
create or replace function public.admin_get_purchase_summary(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text default null
)
returns table(month_purchase numeric, month_po_count int, month_uncosted_po_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  return query
    with month_lines as (
      select l."PONo" as po_no,
             l."UnitCost" as unit_cost,
             coalesce(l."QtyReceived", 0) as qty_received
      from public."PostedPurchaseOrderLines" l
      join public."PostedPurchaseOrders" h on h."PONo" = l."PONo"
      where h."OrderDate" >= v_month_start
        and h."OrderDate" < v_month_end
        -- Scoped on the LINE's warehouse, not the header - a PO can span warehouses, and a
        -- warehouse-scoped user should see only the part that landed in theirs.
        and (p_warehouse_name is null or trim(p_warehouse_name) = '' or l."WarehouseName" = p_warehouse_name)
    )
    select
      coalesce(sum(round(coalesce(unit_cost, 0) * qty_received, 2)), 0)::numeric,
      count(distinct po_no)::int,
      count(distinct po_no) filter (where unit_cost is null and qty_received > 0)::int
    from month_lines;
end;
$$;

grant execute on function public.admin_get_purchase_summary(text, text, text) to anon;
