-- READ-ONLY check: why advance order 10455 (RS-0000011195, ELMER, Amaya, Production Done) can't go
-- Ready to Ship / Shipped. Nothing is changed. Change v_no below for another order.
-- Run the whole file - it ends in ONE result (section / item / detail).

with params as (select '10455'::text as v_no, 'admin'::text as v_user),
prod as (
  select p.*, public._advance_order_prod_status(p) as prod_status
  from public."AdvanceOrderProduction" p, params
  where p."TransactionNo" = params.v_no
),
lines as (
  select li.* from params, public._advance_order_line_items(params.v_no) li
),
tagged as (
  select s.* from params, public._advance_order_serials(params.v_no) s
),
need as (
  select l.item_code, coalesce(l.variation_id, '') as variant, sum(l.quantity)::int as qty
  from lines l where l.needs_serial group by 1, 2
)
-- 1. The order header
select '1 order'::text as section, a."TransactionNo"::text as item,
       format('receipt=%s  warehouse=%s  customer=%s', a."ReceiptNo", a."Warehouse", a."CustomerName")::text as detail
from public."AdvanceOrders" a, params where a."TransactionNo" = params.v_no
union all
-- 2. Production stage (To Ship needs it to not be Assigned)
select '2 production', coalesce(prod_status, '(none = New)'),
       format('tank=%s done=%s | stand=%s done=%s | toShip=%s shipped=%s',
              "TankMaker", "TankDoneAtUtc", "StandMaker", "StandDoneAtUtc", "ToShipAtUtc", "ShippedAtUtc")
from prod
union all
-- 3. Each item line and whether it needs a serial
select '3 line ' || line_no, coalesce(item_code, '(unresolved) ' || coalesce(category, '')),
       format('%s x%s | variant=%s | %s', description, quantity, variation_id, reason)
from lines
union all
-- 4. Serials already tagged to this order
select '4 tagged serial', "SerialNo", format('%s %s status=%s at %s', "ItemCode", coalesce("VariantCode", ''), "Status", "Location")
from tagged
union all
-- 5. In Stock serials at the order's branch for each item that needs one (what the picker can offer)
select '5 in stock @ branch', n.item_code || coalesce('|' || nullif(n.variant, ''), ''),
       format('needs %s | in stock at %s: %s', n.qty, a."Warehouse",
              (select count(*) from public."ItemSerialTracking" s
               where s."ItemCode" = n.item_code and coalesce(s."VariantCode", '') = n.variant
                 and s."Status" = 'IN_STOCK'
                 and lower(coalesce(trim(s."Location"), '')) = lower(coalesce(trim(a."Warehouse"), ''))))
from need n, public."AdvanceOrders" a, params where a."TransactionNo" = params.v_no
union all
-- 6. The user's rights (manager = Super User or Production Manager)
select '6 user', s."Username",
       format('active=%s super=%s roles=%s warehouse=%s is_manager=%s',
              s."IsActive", s."SuperUser", s."StaffRoles", s."WarehouseName", public._production_is_manager(s."Username"))
from public."StaffUsers" s, params where s."Username" = params.v_user
order by 1, 2;
