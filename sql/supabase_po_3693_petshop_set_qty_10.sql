-- Sets EVERY line of the open 3693 Petshop PO (made by supabase_po_3693_petshop_all_items.sql) to
-- 10 pcs. Run AFTER that file.
--
-- 10 pcs = 10 in BASE units: Quantity = 10, QuantityUom = 10 / the line's qty-per-unit (so a line
-- still in pcs reads 10, same as the page's own Qty Ordered edit keeps the two in step).
-- Skips lines that already have anything received (the page locks those too).
-- Safe to re-run - it just sets 10 again.

update public."PurchaseOrderLines" l
   set "Quantity" = 10,
       "QuantityUom" = round(10 / coalesce(nullif(l."QtyPerUnitOfMeasure", 0), 1), 2)
  from public."PurchaseOrders" p
 where p."PONo" = l."PONo"
   and p."VendorCode" = '3693PETSHOP'
   and p."Notes" = '3693 Petshop full price list - type quantities, remove unused lines'
   and coalesce(l."QtyReceived", 0) = 0;

select l."PONo", count(*) as lines, sum(l."Quantity") as total_pcs,
       sum(coalesce(l."UnitCost", 0) * l."Quantity") as total_cost,
       count(*) filter (where l."Quantity" <> 10) as lines_not_10
from public."PurchaseOrderLines" l
join public."PurchaseOrders" p on p."PONo" = l."PONo"
where p."VendorCode" = '3693PETSHOP'
  and p."Notes" = '3693 Petshop full price list - type quantities, remove unused lines'
group by l."PONo";
