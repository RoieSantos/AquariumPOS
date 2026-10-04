-- Read-only: order 109342's serials - per "why we cannot Ready to ship this order" ("Can't create 2 new
-- serial(s) for CI-001 - this order needs 2 and 2 already have a serial").
-- Shows the order's status + lines, and every serial tied to it (SOLD to it or created from it as the
-- source document) with who / when / where it was created, so you can see where the 2 existing CI-001
-- serials came from. One combined result (the SQL editor only shows the last query).

with o as (select '109342'::text as order_id)
select 'order' as section, ord."OrderID"::text as ref, ord."Status"::text as status,
       null::text as item_code, null::text as variant, null::text as location,
       null::text as created_by, null::text as created_at, null::text as updated_by, null::text as updated_at
from public."OnlineOrders" ord, o where ord."OrderID"::text = o.order_id
union all
select 'line', l."LineID"::text, null, coalesce(l."ItemCode", l."product_display_id")::text,
       l."VariationId"::text, null, l."Description"::text, 'qty ' || l."Quantity"::text, null, null
from public."OnlineOrderLines" l, o where l."OrderID"::text = o.order_id
union all
select 'serial', s."SerialNo"::text, s."Status"::text, s."ItemCode"::text, s."VariantCode"::text, s."Location"::text,
       s."CreatedBy"::text, s."CreatedAtUtc"::text, s."UpdatedBy"::text, s."UpdatedAtUtc"::text
from public."ItemSerialTracking" s, o
where s."SoldOnlineOrderId" = o.order_id or s."SourceDocumentNo" = o.order_id
order by 1, 2;
