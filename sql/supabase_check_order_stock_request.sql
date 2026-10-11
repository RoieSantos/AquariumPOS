-- Read-only: why an online order does / doesn't get "Request Production" (branch staff) or
-- "Assign - build missing units" (Production Manager) on Online Orders. Per line: the resolved item code,
-- whether it counts as a serial-tracked stock item (AQ-... or a production category), how many IN_STOCK
-- serials its branch has, plus the order's maker roles / production request / linked Production Order.
-- Same resolution as staff_get_online_order_stock_status. Change the order id on the first line.

with params as (select '116792'::text as order_id),
ord as (
  select o."OrderID"::text as order_id, o."Status", w."Name"::text as warehouse_name,
         public._online_order_production_roles(o."OrderID") as maker_roles,
         o."ProductionRequestedAtUtc", o."ProductionRequestedBy",
         (select string_agg(po."No" || ' (' || po."Status" || ')', ', ') from public."ProductionOrders" po
           where po."SourceOnlineOrderId" = o."OrderID") as production_orders
  from public."OnlineOrders" o
  join params p on p.order_id = o."OrderID"::text
  left join public."Warehouses" w on w."ID" = o."LocationID"
),
resolved as (
  select ord.*, l."Description" as description, l."ItemCode" as line_item_code,
         nullif(trim(l."VariationId"), '') as variation_id,
         greatest(1, ceil(coalesce(l."Quantity", 1)))::int as qty,
         public._online_order_line_part(l."Description", l."ItemCode", l."product_display_id") as custom_part,
         coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), ''), nullif(trim(l."ItemCode"), '')) as item_code,
         coalesce(v."CategoryCode", i."CategoryCode") as category_code
  from ord
  join public."OnlineOrderLines" l on l."OrderID"::text = ord.order_id
  left join public."Variants" v on nullif(trim(l."VariationId"), '') is not null and v."VariationId" = l."VariationId"
  left join public."Items" i on i."Code" = l."ItemCode" or i."VariationId" = l."ItemCode"
)
select r.order_id, r."Status" as status, r.warehouse_name, r.maker_roles,
       r."ProductionRequestedAtUtc" as requested_at, r."ProductionRequestedBy" as requested_by, r.production_orders,
       r.description, r.line_item_code, r.item_code, r.variation_id, r.category_code,
       coalesce(c."IsProductionCategory", false) as production_category,
       r.custom_part,
       (r.custom_part is null and r.item_code is not null
        and (upper(r.item_code) like 'AQ-%' or coalesce(c."IsProductionCategory", false))) as counts_as_stock_item,
       r.qty as needed,
       (select count(*)::int from public."ItemSerialTracking" s
         where s."Status" = 'IN_STOCK' and s."ItemCode" = r.item_code
           and coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(r.variation_id, '')
           and s."Location" = r.warehouse_name) as in_stock_at_branch
from resolved r
left join public."Categories" c on c."Code" = r.category_code
order by r.description;
