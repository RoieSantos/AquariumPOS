-- Blocks posting a Purchase Order until its header Payment Method is set, per direct request
-- ("can we not post the PO if the payment method is blank or not set"). Matches this business's
-- actual process (js/purchaseOrders.js's own note on why Payment Method exists at all: pay first,
-- THEN receive) - by the time a PO is ready to post, how it was paid should already be known, so a
-- blank one here is a data-entry gap worth catching before the order becomes a permanent archive
-- record, the same way the uncosted-received-line check below already catches missing costs.
--
-- Base body is supabase_gl_posting_integration.sql's version of staff_post_purchase_order (the
-- current, latest definition - it replaced supabase_item_cost_and_po_line_cost.sql's own version,
-- adding the blocking uncosted-cost check and the auto-raised Vendor Bill/G-L posting) with this
-- one extra check added first.

drop function if exists public.staff_post_purchase_order(text, text, text);

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
declare
  v_header record;
  v_uncosted_items text;
  v_bill_total numeric;
  v_inventory_account text;
  v_bill record;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_header from public."PurchaseOrders" where "PONo" = p_po_no;

  if not found then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  if v_header."PaymentMethod" is null then
    raise exception 'Cannot post - set a Payment Method for this Purchase Order first.';
  end if;

  select string_agg(distinct "ItemCode", ', ')
    into v_uncosted_items
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no
    and coalesce("QtyReceived", 0) > 0
    and "UnitCost" is null;

  if v_uncosted_items is not null then
    raise exception 'Cannot post - these received items have no unit cost: %. Enter a cost on each line first, or the vendor bill would understate what is owed.', v_uncosted_items;
  end if;

  select coalesce(sum(round(coalesce("UnitCost", 0) * coalesce("QtyReceived", 0), 2)), 0)
    into v_bill_total
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no;

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

  if v_bill_total > 0 then
    select s."InventoryAccountNo" into v_inventory_account from public."GLSetup" s limit 1;

    -- Goods bought for resale are an asset until sold, so a purchase debits Inventory, not an
    -- expense account. Cost of Goods Sold is recognised when the item sells - which is the sales
    -- posting this build deliberately leaves for later.
    -- The internal helper, not admin_create_vendor_bill: posting a PO is is_staff_authorized, so
    -- routing through the super-user wrapper would fail for ordinary staff. The caller has
    -- already been authorized above.
    select * into v_bill from public._create_vendor_bill(
      v_header."VendorCode",
      v_header."OrderDate",
      null,
      p_po_no,
      v_bill_total,
      'Auto-raised on posting Purchase Order ' || p_po_no,
      v_inventory_account,
      p_po_no,
      p_admin_username
    );

    -- _create_vendor_bill reports failure in its result rather than raising, so it is checked
    -- explicitly - otherwise a G/L Setup problem would silently post the PO with no bill and no
    -- ledger entry, which is exactly the split the whole feature exists to prevent. Raising here
    -- rolls the entire posting back.
    if not v_bill.success then
      raise exception 'Purchase Order was not posted - could not raise the vendor bill: %', v_bill.message;
    end if;
  end if;
end;
$$;

grant execute on function public.staff_post_purchase_order(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect exactly one row.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_post_purchase_order';
