-- READ-ONLY check: are the serials a store POS sells actually tagged to the order?
--
-- At a POS sale the cashier picks a serial for each serial-tracked unit (AQ- / production-category
-- items). After posting, the POS marks it SOLD locally with SoldReceiptNo = the receipt and
-- SoldOnlineOrderId = the WI- order the sale got in the portal, then pushes that to Supabase
-- (ProductSerialTrackingForm.MarkSerialsSold -> SyncItemSerialTrackingToSupabaseAsync).
-- The portal's order Serials FactBox only looks at SoldOnlineOrderId, so a serial linked by receipt
-- only doesn't show on the WI- order.
--
-- For every WI- walk-in in the last 30 days that has serial-tracked lines, this compares:
--   units      - serial-tracked quantity on the order
--   by_order   - serials with SoldOnlineOrderId = the WI- order (what the portal shows)
--   by_receipt - serials with SoldReceiptNo = the receipt but NOT the WI- id (sold, but not on the order)
-- Problem rows first. One result. Safe to re-run (changes nothing).

with wi as (
  select o."OrderID", o."PosReceiptNo", o."Date", o."PosWarehouseId"
  from public."OnlineOrders" o
  where o."OrderID" like 'WI-%'
    and o."Date" >= (now() at time zone 'Asia/Manila')::date - 30
),
lines as (
  select w."OrderID",
         sum(greatest(ceil(coalesce(l."Quantity", 0)), 0))::int as units
  from wi w
  join public."OnlineOrderLines" l on l."OrderID" = w."OrderID"
  left join public."Variants" v on nullif(trim(l."VariationId"), '') is not null and v."VariationId" = trim(l."VariationId")
  left join public."Items" i on i."Code" = coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(v."MainItemCode"), ''), nullif(trim(l."ItemCode"), ''))
  left join public."Categories" c on c."Code" = coalesce(v."CategoryCode", i."CategoryCode")
  where coalesce(c."IsProductionCategory", false)
     or upper(coalesce(i."Code", l."ItemCode", '')) like 'AQ-%'
  group by w."OrderID"
),
per_order as (
  select w."OrderID", w."PosReceiptNo", w."Date", w."PosWarehouseId", l.units,
         (select count(*) from public."ItemSerialTracking" s
           where s."SoldOnlineOrderId" = w."OrderID")::int as by_order,
         (select count(*) from public."ItemSerialTracking" s
           where nullif(w."PosReceiptNo", '') is not null
             and s."SoldReceiptNo" = w."PosReceiptNo"
             and s."SoldOnlineOrderId" is distinct from w."OrderID")::int as by_receipt,
         (select string_agg(s."SerialNo" || ' (' || s."Status" || ')', ', ' order by s."SerialNo")
            from public."ItemSerialTracking" s
           where s."SoldOnlineOrderId" = w."OrderID"
              or (nullif(w."PosReceiptNo", '') is not null and s."SoldReceiptNo" = w."PosReceiptNo")) as serials
  from wi w
  join lines l on l."OrderID" = w."OrderID"
),
rated as (
  select p.*,
         case
           when p.by_order >= p.units then 'OK - all units tagged to the order'
           when p.by_order + p.by_receipt >= p.units then 'RECEIPT ONLY - sold, but not linked to the WI- order (portal won''t show them)'
           when p.by_order + p.by_receipt = 0 then 'NO SERIALS - nothing tagged (sold without picking, or push not synced yet)'
           else 'PARTIAL - fewer serials than units'
         end as verdict
  from per_order p
)
select section, order_id, receipt_no, sale_date, warehouse, units, by_order, by_receipt, verdict, serials
from (
  select 0 as sort_rank, 'summary' as section,
         null::text as order_id, null::text as receipt_no, null::date as sale_date, null::text as warehouse,
         sum(units)::int as units, sum(by_order)::int as by_order, sum(by_receipt)::int as by_receipt,
         count(*) filter (where verdict like 'OK%') || ' OK / ' || count(*) || ' walk-ins with serial-tracked lines' as verdict,
         null::text as serials
  from rated
  union all
  select case when verdict like 'OK%' then 2 else 1 end, 'order', "OrderID", "PosReceiptNo", "Date", "PosWarehouseId",
         units, by_order, by_receipt, verdict, serials
  from rated
) x
order by sort_rank, sale_date desc nulls first, order_id desc;
