-- Manual Purchase Order to 3693 Petshop with ALL their products, quantity 0 - you type the quantities
-- in on the Purchase Orders page.
-- Run AFTER supabase_vendor_3693_petshop_import.sql (that file creates the vendor and links the 55
-- items to it in the Item Vendor catalog - this PO takes its lines from that catalog).
--
-- One open PO, numbered from the normal PURCHASE-ORDER No. Series, one line per item 3693 Petshop
-- supplies (catalog OR primary vendor), Unit Cost = their price from the catalog (falls back to
-- Items.Cost), base unit, no warehouse yet.
--
-- On the page afterwards:
--   - set the Warehouse (header) - it fills every line too;
--   - type each line's Quantity (the page only accepts > 0, so a line stays at 0 until you edit it);
--   - REMOVE the lines you're not ordering before posting - a 0-qty line would post as an empty line.
--
-- Not safe to blindly re-run: it STOPS if an open (unposted) PO made by this file already exists
-- for 3693 Petshop, so you don't get two. Delete/post that one first if you really want a fresh one.

do $$
declare
  v_vendor constant text := '3693PETSHOP';
  v_marker constant text := '3693 Petshop full price list - type quantities, remove unused lines';
  v_po_no text;
  v_existing text;
  v_lines int;
begin
  if not exists (select 1 from public."Vendors" where "VendorCode" = v_vendor) then
    raise exception 'Vendor % not found - run supabase_vendor_3693_petshop_import.sql first.', v_vendor;
  end if;

  select "PONo" into v_existing from public."PurchaseOrders"
   where "VendorCode" = v_vendor and "Notes" = v_marker
   limit 1;
  if v_existing is not null then
    raise exception 'Open PO % from this file already exists for 3693 Petshop - nothing created.', v_existing;
  end if;

  v_po_no := public._next_no_series_number('PURCHASE-ORDER', '');

  insert into public."PurchaseOrders" ("PONo", "VendorCode", "Notes", "CreatedBy")
  values (v_po_no, v_vendor, v_marker, 'SQL: 3693 Petshop list');

  insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "Quantity", "QuantityUom", "Description", "UnitCost")
  select v_po_no, i."Code", coalesce(nullif(trim(i."Name"), ''), i."Code"), 0, 0,
         nullif(trim(coalesce(iv."VendorItemNo", '')), ''),
         coalesce(iv."Cost", i."Cost")
  from public."Items" i
  left join public."ItemVendors" iv on iv."ItemCode" = i."Code" and iv."VendorCode" = v_vendor
  where (iv."ItemCode" is not null or i."VendorCode" = v_vendor)
    and coalesce(i."IsActive", true)
  order by i."Name";
  get diagnostics v_lines = row_count;

  if v_lines = 0 then
    raise exception 'No items are linked to 3693 Petshop yet - run supabase_vendor_3693_petshop_import.sql first.';
  end if;
end;
$$;

select l."PONo", l."EntryNo", l."ItemCode", l."ItemName", l."UnitCost", l."Quantity"
from public."PurchaseOrderLines" l
join public."PurchaseOrders" p on p."PONo" = l."PONo"
where p."VendorCode" = '3693PETSHOP'
  and p."Notes" = '3693 Petshop full price list - type quantities, remove unused lines'
order by l."ItemName";
