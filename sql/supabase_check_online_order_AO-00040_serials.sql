-- Read-only: what will Ready to Ship ask for on order AO-00040?
-- AO-00040 is a bot / GMA order confirmed into Online Orders (OrderID = 'AO-00040', Source 'Portal' -
-- supabase_bot_orders_portal_confirm.sql), NOT an advance order. Same logic as
-- admin_get_online_order_serial_requirements (latest: supabase_online_order_stock_status_set.sql) plus the
-- page's "already has a SOLD serial" subtraction (getOrderSerialRequirements in js/onlineOrders.js).
--   order  - status, source, makers
--   line   - every order line: resolved item / category and whether it needs a serial
--   needs  - serial lines: qty / already tagged / STILL TO TAG (> 0 = it WILL ask)
--   serial - serials already tied to the order
-- No 'needs' row with STILL TO TAG > 0 -> no serial step, straight to "Order complete?".

with lines as (
  select l."LineID" as line_id, l."Description" as descr, l."Quantity" as qty,
         nullif(trim(l."VariationId"), '') as variation_id,
         coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), ''), nullif(trim(l."ItemCode"), '')) as code,
         coalesce(v."CategoryCode", i."CategoryCode") as category,
         upper(public._online_order_line_category(l."VariationId",
               coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), '')))) = 'SET' as is_set
  from public."OnlineOrderLines" l
  left join lateral (
    select v0."ItemCode", v0."CategoryCode" from public."Variants" v0
    where nullif(trim(l."VariationId"), '') is not null and v0."VariationId" = l."VariationId"
    limit 1
  ) v on true
  left join lateral (
    select i0."Code", i0."CategoryCode" from public."Items" i0
    where i0."Code" = l."ItemCode" or i0."VariationId" = l."ItemCode"
    order by (i0."Code" = l."ItemCode") desc
    limit 1
  ) i on true
  where l."OrderID" = 'AO-00040'
),
judged as (
  select ln.*,
         (not ln.is_set and ln.code is not null and (
            upper(ln.code) like 'AQ-%' or upper(ln.code) like 'CUSTOM-AQUARIUM%'
            or upper(ln.code) like 'CUSTOM_STAND%' or upper(ln.code) like 'CUSTOM-SUMP%'
            or upper(ln.code) like 'CUSTOM_SUMP%' or coalesce(c."IsProductionCategory", false))) as needs_serial
  from lines ln
  left join public."Categories" c on c."Code" = ln.category
),
owned as (
  select s."ItemCode" as code, coalesce(trim(s."VariantCode"), '') as variant, count(*)::int as n
  from public."ItemSerialTracking" s
  where s."SoldOnlineOrderId" = 'AO-00040' and s."Status" = 'SOLD'
  group by 1, 2
)
select 'order' as section,
       format('status=%s | source=%s | tank maker=%s | stand maker=%s',
              o."Status", coalesce(o."Source", '-'),
              coalesce(o."AssignedTankMaker", '-'), coalesce(o."AssignedStandMaker", '-')) as detail
from public."OnlineOrders" o
where o."OrderID" = 'AO-00040'
union all
select 'line ' || j.line_id,
       format('%s | qty=%s | item=%s | category=%s | %s', left(coalesce(j.descr, ''), 60), j.qty,
              coalesce(j.code, '(not found)'), coalesce(j.category, '-'),
              case when j.is_set then 'no - SET line (its parts carry the serials)'
                   when j.needs_serial then 'YES - needs a serial'
                   when j.code is null then 'no - item not found'
                   else 'no - not a production item' end)
from judged j
union all
select 'needs',
       format('%s | %s | qty=%s | already tagged=%s | STILL TO TAG=%s | %s',
              j.code, left(coalesce(j.descr, ''), 50), greatest(1, ceil(coalesce(j.qty, 1)))::int, coalesce(w.n, 0),
              greatest(greatest(1, ceil(coalesce(j.qty, 1)))::int - coalesce(w.n, 0), 0),
              case when j.code ~* '(^|[^a-z])custom[\s_-]*(aquarium|tank|stand|sump|cabinet)'
                     or j.descr ~* '(^|[^a-z])custom[\s_-]*(aquarium|tank|stand|sump|cabinet)'
                   then 'custom build - new serial'
                   else 'pick In Stock serial (or + New serial)' end)
from judged j
left join owned w on w.code = j.code and w.variant = coalesce(j.variation_id, '')
where j.needs_serial
union all
select 'serial', s."SerialNo" || ' (' || s."ItemCode" || ') ' || coalesce(s."Status", '')
from public."ItemSerialTracking" s
where s."SoldOnlineOrderId" = 'AO-00040'
union all
-- if nothing above shows, the order isn't in Online Orders yet - this row says where it is
select 'not in online orders', format('AutomatedOrders status=%s | sync=%s', a."Status", coalesce(a."PancakeSyncStatus", '-'))
from public."AutomatedOrders" a
where a."OrderNo" = 'AO-00040'
  and not exists (select 1 from public."OnlineOrders" o where o."OrderID" = 'AO-00040')
order by 1;
