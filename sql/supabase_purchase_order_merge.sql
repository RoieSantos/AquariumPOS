-- Merge two open Purchase Orders from the same vendor, per "can we create a functionality to merge
-- both purchase orders with same vendor?". From an open PO's card (super users), "Merge" lists the
-- vendor's other open POs; picking one moves its lines into the open one and deletes it.
--
--   staff_list_mergeable_purchase_orders(target) - the vendor's other open POs, with a can_merge
--     flag (false once anything was received against it).
--   staff_merge_purchase_orders(target, source)  - does the merge, in one transaction.
--
-- Rules:
--   * Both must still be open (in "PurchaseOrders", not posted) and have the same VendorCode.
--   * The SOURCE (the one that disappears) must have nothing received and no Pancake purchase
--     events: every receipt is pushed to Pancake under its own PONo
--     ("PurchaseOrder_Pancake_Purchases"), and moving those lines would leave that history pointing
--     at a PO that no longer exists. The TARGET may already be partly received - that's fine.
--   * A source line identical to a target line (same item, variant, warehouse, unit of measure,
--     conversion and unit cost) whose target line has received nothing yet is folded into it
--     (quantities added). Anything else is moved across as its own line, unchanged (EntryNo kept).
--   * Target header (order date, warehouse, payment method) wins; a blank payment method on the
--     target takes the source's. The source's notes are appended to the target's with a
--     "Merged from PO-xxxx" marker.
--
-- Super-user only (is_admin_authorized), same as every other edit to an existing PO
-- (supabase_purchase_order_edit_lines.sql). Run AFTER the existing PO scripts
-- (supabase_purchase_order_line_variant.sql, supabase_units_of_measure.sql,
-- supabase_purchase_order_payment_method.sql, supabase_purchase_order_pancake_sync.sql).
-- Safe to re-run.

drop function if exists public.staff_list_mergeable_purchase_orders(text, text, text);

create or replace function public.staff_list_mergeable_purchase_orders(
  p_admin_username text,
  p_admin_password text,
  p_target_po_no text
)
returns table(
  po_no text,
  order_date date,
  warehouse_name text,
  notes text,
  line_count bigint,
  total_quantity numeric,
  total_received_quantity numeric,
  can_merge boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_vendor_code text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can merge Purchase Orders.';
  end if;

  select "VendorCode" into v_vendor_code from public."PurchaseOrders" where "PONo" = p_target_po_no;
  if not found then
    raise exception 'Purchase Order % not found - it may already be posted.', p_target_po_no;
  end if;

  return query
    select po."PONo"::text, po."OrderDate", po."WarehouseName"::text, po."Notes"::text,
           count(l."EntryNo"), coalesce(sum(l."Quantity"), 0), coalesce(sum(l."QtyReceived"), 0),
           coalesce(sum(l."QtyReceived"), 0) = 0
             and not exists (select 1 from public."PurchaseOrder_Pancake_Purchases" pp where pp."PONo" = po."PONo")
    from public."PurchaseOrders" po
    left join public."PurchaseOrderLines" l on l."PONo" = po."PONo"
    where po."VendorCode" = v_vendor_code
      and po."PONo" <> p_target_po_no
    group by po."PONo", po."OrderDate", po."WarehouseName", po."Notes", po."CreatedAtUtc"
    order by po."CreatedAtUtc";
end;
$$;

grant execute on function public.staff_list_mergeable_purchase_orders(text, text, text) to anon;

drop function if exists public.staff_merge_purchase_orders(text, text, text, text);

-- Returns how many source lines were folded into existing target lines vs moved as new lines.
create or replace function public.staff_merge_purchase_orders(
  p_admin_username text,
  p_admin_password text,
  p_target_po_no text,
  p_source_po_no text
)
returns table(lines_combined int, lines_moved int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_target public."PurchaseOrders"%rowtype;
  v_source public."PurchaseOrders"%rowtype;
  v_line public."PurchaseOrderLines"%rowtype;
  v_match_entry bigint;
  v_combined int := 0;
  v_moved int := 0;
  v_note text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can merge Purchase Orders.';
  end if;

  if p_target_po_no is null or p_source_po_no is null or p_target_po_no = p_source_po_no then
    raise exception 'Pick two different Purchase Orders to merge.';
  end if;

  -- Lock both headers (always in the same order) so a concurrent receive/post/merge can't interleave.
  perform 1 from public."PurchaseOrders"
  where "PONo" in (p_target_po_no, p_source_po_no)
  order by "PONo"
  for update;

  select * into v_target from public."PurchaseOrders" where "PONo" = p_target_po_no;
  if not found then
    raise exception 'Purchase Order % not found - it may already be posted.', p_target_po_no;
  end if;

  select * into v_source from public."PurchaseOrders" where "PONo" = p_source_po_no;
  if not found then
    raise exception 'Purchase Order % not found - it may already be posted or merged.', p_source_po_no;
  end if;

  if v_target."VendorCode" is distinct from v_source."VendorCode" then
    raise exception 'Only Purchase Orders from the same vendor can be merged (% is %, % is %).',
      p_target_po_no, v_target."VendorCode", p_source_po_no, v_source."VendorCode";
  end if;

  if exists (select 1 from public."PurchaseOrderLines" where "PONo" = p_source_po_no and "QtyReceived" > 0)
     or exists (select 1 from public."PurchaseOrder_Pancake_Purchases" where "PONo" = p_source_po_no) then
    raise exception '% has already received stock (pushed to Pancake under its own number) - it can''t be merged away. Merge the other way round instead (open % and merge % into it).',
      p_source_po_no, p_source_po_no, p_target_po_no;
  end if;

  for v_line in
    select * from public."PurchaseOrderLines" where "PONo" = p_source_po_no order by "EntryNo"
  loop
    select t."EntryNo" into v_match_entry
    from public."PurchaseOrderLines" t
    where t."PONo" = p_target_po_no
      and coalesce(t."QtyReceived", 0) = 0
      and t."ItemCode" = v_line."ItemCode"
      and t."VariantCode" is not distinct from v_line."VariantCode"
      and t."WarehouseId" is not distinct from v_line."WarehouseId"
      and t."UnitOfMeasureCode" is not distinct from v_line."UnitOfMeasureCode"
      and coalesce(t."QtyPerUnitOfMeasure", 1) = coalesce(v_line."QtyPerUnitOfMeasure", 1)
      and t."UnitCost" is not distinct from v_line."UnitCost"
    order by t."EntryNo"
    limit 1;

    if v_match_entry is not null then
      update public."PurchaseOrderLines" t
      set "Quantity" = t."Quantity" + v_line."Quantity",
          "QuantityUom" = case
            when t."QuantityUom" is null and v_line."QuantityUom" is null then null
            else coalesce(t."QuantityUom", t."Quantity") + coalesce(v_line."QuantityUom", v_line."Quantity")
          end
      where t."EntryNo" = v_match_entry;

      delete from public."PurchaseOrderLines" where "EntryNo" = v_line."EntryNo";
      v_combined := v_combined + 1;
    else
      update public."PurchaseOrderLines" set "PONo" = p_target_po_no where "EntryNo" = v_line."EntryNo";
      v_moved := v_moved + 1;
    end if;
  end loop;

  v_note := 'Merged from ' || p_source_po_no
    || coalesce(': ' || nullif(trim(coalesce(v_source."Notes", '')), ''), '');

  update public."PurchaseOrders"
  set "Notes" = left(concat_ws(' | ', nullif(trim(coalesce("Notes", '')), ''), v_note), 1000),
      "PaymentMethod" = coalesce("PaymentMethod", v_source."PaymentMethod")
  where "PONo" = p_target_po_no;

  -- Lines are all gone from the source by now; the header goes too.
  delete from public."PurchaseOrders" where "PONo" = p_source_po_no;

  return query select v_combined, v_moved;
end;
$$;

grant execute on function public.staff_merge_purchase_orders(text, text, text, text) to anon;
