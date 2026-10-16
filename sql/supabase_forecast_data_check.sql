-- Forecasting - PHASE 0 DATA CHECK (read-only), per "can we build forecasting?" -> "okay lets build
-- this". Before building a demand forecast for the Production Shelf Map we need to know how much sales
-- history each shelf product actually has, per location. Nothing is written; safe to run any time.
--
-- Sales history = OnlineOrders + OnlineOrderLines (synced from Pancake, walk-ins included), NOT the
-- Item Ledger, which only has sales since "Start Posting Sales". Same "counts as a sale" rule as ledger
-- sales posting (_ile_order_counts_as_sale: not cancelled / removed / returned / refunded / deleted),
-- dated by the order's "Date" (which already honours a portal DateOverride), at the order's LocationID.
-- SET packages count through their exploded component lines (supabase_online_order_set_explode.sql).
--
-- A shelf product matches lines the same way the page matches serials to a rack (unitFitsSpot in
-- docs/js/productionShelfMap.js): a rack linked to one variant -> that VariationId only; an "Any
-- variant" rack -> every line of the item, including a variant that has its own item row.
--
-- ONE RESULT, two sections:
--   1 location   - per order location: date range of orders, months of history, orders in the last
--                  90 days / 26 weeks / 365 days / all time. "pattern" lists data gaps (orders with
--                  no lines, sale orders with no location).
--   2 shelf      - per product linked to a rack: first/last sale at that location, units sold in the
--                  last 90 days / 26 weeks / 365 days / all time, how many of the last 26 weeks had a
--                  sale, and the demand pattern that decides the forecast method:
--                    smooth       - sold in 13+ of the last 26 weeks -> moving average
--                    intermittent - sold in 3-12 of the 26 weeks      -> Croston (sporadic demand)
--                    rare         - sold in 1-2 of the 26 weeks       -> too little to forecast, keep manual min
--                    no sales     - nothing in 26 weeks
--
-- Run AFTER supabase_production_shelf_size_tags.sql (rack ItemCode / VariantId). Read-only.

with
today as (
  select (now() at time zone 'Asia/Manila')::date as d
),
sale_orders as (
  select o."OrderID", o."Date" as sale_date, coalesce(o."LocationID", '') as warehouse_id
  from public."OnlineOrders" o
  where public._ile_order_counts_as_sale(o."Status") and o."Date" is not null
),
sale_lines as (
  select
    so.warehouse_id,
    so.sale_date,
    so."OrderID",
    coalesce(v."ItemCode", l."ItemCode") as item_code,
    v."MainItemCode" as main_item_code,
    nullif(trim(coalesce(l."VariationId", '')), '') as variation_id,
    l."Quantity" as qty
  from sale_orders so
  join public."OnlineOrderLines" l on l."OrderID" = so."OrderID"
  left join public."Variants" v on v."VariationId" = l."VariationId"
  where coalesce(l."Quantity", 0) > 0
),
shelf_products as (
  select sh."WarehouseId" as warehouse_id, sp."ItemCode" as item_code, coalesce(sp."VariantId", '') as variant_id,
         max(case when length(sp."Label") > 4 then sp."Label" end) as label
  from public."ProductionShelfSpots" sp
  join public."ProductionShelves" sh on sh."Id" = sp."ShelfId"
  where nullif(trim(coalesce(sp."ItemCode", '')), '') is not null
  group by sh."WarehouseId", sp."ItemCode", coalesce(sp."VariantId", '')
),
shelf_sales as (
  select p.warehouse_id, p.item_code, p.variant_id, p.label, sl.sale_date, sl.qty
  from shelf_products p
  left join sale_lines sl
    on sl.warehouse_id = p.warehouse_id
   and case when p.variant_id <> '' then sl.variation_id = p.variant_id
            else sl.item_code = p.item_code or sl.main_item_code = p.item_code end
),
shelf_rollup as (
  select
    s.warehouse_id, s.item_code, s.variant_id, s.label,
    min(s.sale_date) as first_sale,
    max(s.sale_date) as last_sale,
    coalesce(sum(s.qty) filter (where s.sale_date > t.d - 90), 0) as units_90d,
    coalesce(sum(s.qty) filter (where s.sale_date > t.d - 182), 0) as units_26w,
    count(distinct date_trunc('week', s.sale_date)) filter (where s.sale_date > t.d - 182) as weeks_sold_26w,
    coalesce(sum(s.qty) filter (where s.sale_date > t.d - 365), 0) as units_365d,
    coalesce(sum(s.qty), 0) as units_all
  from shelf_sales s cross join today t
  group by s.warehouse_id, s.item_code, s.variant_id, s.label
),
location_rollup as (
  select
    so.warehouse_id,
    min(so.sale_date) as first_sale,
    max(so.sale_date) as last_sale,
    count(*) filter (where so.sale_date > t.d - 90) as orders_90d,
    count(*) filter (where so.sale_date > t.d - 182) as orders_26w,
    count(*) filter (where so.sale_date > t.d - 365) as orders_365d,
    count(*) as orders_all,
    count(*) filter (where not exists (select 1 from public."OnlineOrderLines" l where l."OrderID" = so."OrderID")) as orders_no_lines
  from sale_orders so cross join today t
  group by so.warehouse_id
)
select
  '1 location' as section,
  coalesce(w."Name", nullif(r.warehouse_id, ''), '(no location)')::text as warehouse,
  '(all sale orders - counts are ORDERS)'::text as product,
  ''::text as item_code,
  ''::text as variant,
  r.first_sale,
  r.last_sale,
  round(((r.last_sale - r.first_sale) / 30.4)::numeric, 1) as months_history,
  r.orders_90d::numeric as units_90d,
  r.orders_26w::numeric as units_26w,
  null::bigint as weeks_sold_26w,
  r.orders_365d::numeric as units_365d,
  r.orders_all::numeric as units_all,
  (case when r.orders_no_lines > 0 then r.orders_no_lines || ' order(s) with no lines synced' else 'all orders have lines' end
   || case when r.warehouse_id = '' then ' - NO LOCATION, these can''t be assigned to a branch' else '' end)::text as pattern
from location_rollup r
left join public."Warehouses" w on w."ID" = r.warehouse_id

union all

select
  '2 shelf',
  coalesce(w."Name", r.warehouse_id)::text,
  coalesce(r.label, r.item_code)::text,
  r.item_code::text,
  case when r.variant_id = '' then 'any variant' else coalesce(v."SKU", v."VariantName", r.variant_id) end::text,
  r.first_sale,
  r.last_sale,
  round(((r.last_sale - r.first_sale) / 30.4)::numeric, 1),
  r.units_90d,
  r.units_26w,
  r.weeks_sold_26w,
  r.units_365d,
  r.units_all,
  case
    when r.weeks_sold_26w >= 13 then 'smooth'
    when r.weeks_sold_26w >= 3 then 'intermittent'
    when r.weeks_sold_26w >= 1 then 'rare'
    else 'no sales'
  end
from shelf_rollup r
left join public."Warehouses" w on w."ID" = r.warehouse_id
left join public."Variants" v on v."VariationId" = nullif(r.variant_id, '')

order by 1, 2, 3;
