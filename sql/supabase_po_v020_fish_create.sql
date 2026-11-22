-- One-off (2026-11-21): create the IsdaPoko (V020) fish Purchase Order, received into "Warehouse".
-- Same inserts as staff_create_purchase_order (no staff password available to call it directly).
-- NOT safe to re-run: each run creates another PO.
do $$
declare
  v_wh_id text := 'bd5cb2df-e9de-43ac-b566-ae8651ab60de';
  v_wh_name text := 'Warehouse';
  v_po_no text;
begin
  v_po_no := public._next_no_series_number('PURCHASE-ORDER', '');

  insert into public."PurchaseOrders" ("PONo", "VendorCode", "Notes", "CreatedBy", "WarehouseId", "WarehouseName")
  values (v_po_no, 'V020', 'IsdaPoko fish order - total P9,200', 'admin', v_wh_id, v_wh_name);

  insert into public."PurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "UnitCost")
  select v_po_no, i."Code", i."Name", v_wh_id, v_wh_name, l.qty, l.cost
  from (values
    (1,  'F-169',  50,  20),   -- Black Angel          P1000
    (2,  'F-087',  50,   5),   -- Tiger Barb           P250
    (3,  'F-118',  50,  15),   -- Green Sumatra        P750
    (4,  'F-056', 400,   9),   -- Glo Tetra random     P3600
    (5,  'F-033', 100,  10),   -- Danio random         P1000
    (6,  'F-170',  20,  25),   -- Longfin Danio        P500
    (7,  'F-97',   50,  10),   -- Kohaku Red Eye       P500
    (8,  'F-020',  25,  20),   -- Local Oranda         P500
    (9,  'F-146',   3, 200),   -- Albino Gibbi         P600
    (10, 'F-162',  20,  25)    -- Juli Cory            P500
  ) l(seq, code, qty, cost)
  join public."Items" i on i."Code" = l.code
  order by l.seq;

  raise notice 'Created %', v_po_no;
end $$;

select h."PONo", h."VendorCode", h."WarehouseName", count(*) as lines, sum(l."Quantity") as pcs, sum(l."Quantity" * l."UnitCost") as total
from public."PurchaseOrders" h join public."PurchaseOrderLines" l on l."PONo" = h."PONo"
where h."VendorCode" = 'V020'
group by 1,2,3 order by 1 desc;
