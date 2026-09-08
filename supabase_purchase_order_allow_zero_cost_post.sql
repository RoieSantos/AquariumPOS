-- Relaxes staff_post_purchase_order's uncosted-received-line check, per direct request ("please
-- allow if the unit cost is 0"). Previously any received line with UnitCost still null hard-
-- blocked posting entirely - but Unit Cost also locks to read-only the moment a line has any
-- QtyReceived (purchaseOrders.js unitCostCell: "editable = ... qty_received === 0"), so a line
-- that got received with no cost (e.g. via "Confirm Received (Already in Pancake)") had no way
-- left to ever satisfy the block. That combination was a dead end, not a safeguard.
--
-- Now: an uncosted received line just posts at $0 for that line (coalesce("UnitCost", 0), same as
-- the bill-total calc already did) instead of refusing to post at all. Nothing is hidden - the
-- Total Cost note on both the Purchase Orders and Posted Purchase Orders pages already calls out
-- "Excludes N item(s) with no Unit Cost - total is understated" whenever this happens.
--
-- Base body is supabase_purchase_order_require_payment_method_to_post.sql's version (the current,
-- latest definition) with only the uncosted-items raise removed - the Payment Method check and
-- everything else (vendor bill raise, GL posting, last-cost writeback) stays exactly as is.

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
