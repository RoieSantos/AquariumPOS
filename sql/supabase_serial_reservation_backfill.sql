-- One-off: reserve the serials that were ALREADY built for an order before reservations existed - per
-- "i got order 1 i assign to maker then serials has been created.. but later on another customer walk in
-- then grab that serials".
--
-- Every serial posted by a Production Order linked to an order (ProductionOrders.SourceOnlineOrderId)
-- that is still IN_STOCK, while that order is still open (_serial_order_is_open), becomes RESERVED for it
-- - same as supabase_serial_order_reservation.sql now does at Post Output. Capped per order + item +
-- variant at the units the order still needs (its serial-tracked lines minus serials already SOLD to it),
-- oldest serial first, so an order never holds more than it can ship.
--
-- The result also lists the serials those builds made that went to SOMEONE ELSE (sold to another receipt /
-- order, or moved) while the order is still open - the "lost" units, so you know which orders are short -
-- and any built for an open order that stayed In Stock unreserved (extra units / variant mismatch).
--
-- Run AFTER supabase_serial_order_reservation.sql. Safe to re-run (a second run finds nothing new to
-- reserve). One statement, one result.

with built as (
  -- serials output by a Production Order built for a still-open order
  select s."RunningSerialNo", s."SerialNo", s."ItemCode", coalesce(nullif(trim(s."VariantCode"), ''), '') as variant,
         s."Status", s."CreatedAtUtc", po."No" as prod_order, trim(po."SourceOnlineOrderId") as order_id
  from public."ProductionOrders" po
  join public."ProductionOrderOutputs" o on o."ProdOrderNo" = po."No"
  join public."ProductionOrderOutputSerials" os on os."EntryNo" = o."EntryNo"
  join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
  where nullif(trim(po."SourceOnlineOrderId"), '') is not null
    and public._serial_order_is_open(trim(po."SourceOnlineOrderId"))
),
needed as (
  -- units each order still needs per item/variant: its serial-tracked lines (same rule as
  -- admin_get_online_order_serial_requirements) minus serials already SOLD / RESERVED for it
  select ord.order_id, r.item_code, r.variant, greatest(r.qty - coalesce(t.n, 0), 0) as still_needed
  from (select distinct order_id from built) ord
  cross join lateral (
    select coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), ''), nullif(trim(l."ItemCode"), '')) as item_code,
           coalesce(nullif(trim(l."VariationId"), ''), '') as variant,
           sum(greatest(1, ceil(coalesce(l."Quantity", 1))))::int as qty
    from public."OnlineOrderLines" l
    left join lateral (select v0."ItemCode" from public."Variants" v0
                       where nullif(trim(l."VariationId"), '') is not null and v0."VariationId" = l."VariationId" limit 1) v on true
    left join lateral (select i0."Code" from public."Items" i0
                       where i0."Code" = l."ItemCode" or i0."VariationId" = l."ItemCode"
                       order by (i0."Code" = l."ItemCode") desc limit 1) i on true
    where l."OrderID" = ord.order_id
    group by 1, 2
  ) r
  left join lateral (
    select count(*)::int as n from public."ItemSerialTracking" s
    where s."ItemCode" = r.item_code and coalesce(nullif(trim(s."VariantCode"), ''), '') = r.variant
      and ((s."Status" = 'SOLD' and s."SoldOnlineOrderId" = ord.order_id)
           or (s."Status" = 'RESERVED' and s."ReservedForOrderId" = ord.order_id))
  ) t on true
),
picked as (
  select b.*, row_number() over (partition by b.order_id, b."ItemCode", b.variant order by b."CreatedAtUtc", b."SerialNo") as rn
  from built b
  where b."Status" = 'IN_STOCK'
),
reserved as (
  update public."ItemSerialTracking" s
     set "Status" = 'RESERVED', "ReservedForOrderId" = p.order_id, "ReservedAtUtc" = now(),
         "ReservedBy" = 'backfill', "UpdatedAtUtc" = now(), "UpdatedBy" = 'reservation backfill'
  from picked p
  join needed n on n.order_id = p.order_id and n.item_code = p."ItemCode" and n.variant = p.variant
  where s."RunningSerialNo" = p."RunningSerialNo" and s."Status" = 'IN_STOCK' and p.rn <= n.still_needed
  returning s."SerialNo" as serial_no, p.order_id, s."ItemCode" as item_code, p.prod_order
)
-- What was reserved now, then the built-for-an-order serials that went elsewhere.
select 'reserved now' as section, b.order_id, b.serial_no::text, b.item_code::text, b.prod_order::text,
       'RESERVED'::text as status, null::text as went_to
from reserved b
union all
select 'built for this order but taken by someone else', trim(po."SourceOnlineOrderId"), s."SerialNo", s."ItemCode", po."No",
       s."Status",
       coalesce(nullif(trim(s."SoldOnlineOrderId"), ''), 'receipt ' || nullif(trim(s."SoldReceiptNo"), ''),
                'order ' || nullif(trim(s."ReservedForOrderId"), ''), s."Location")
from public."ProductionOrders" po
join public."ProductionOrderOutputs" o on o."ProdOrderNo" = po."No"
join public."ProductionOrderOutputSerials" os on os."EntryNo" = o."EntryNo"
join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
where nullif(trim(po."SourceOnlineOrderId"), '') is not null
  and public._serial_order_is_open(trim(po."SourceOnlineOrderId"))
  and s."Status" not in ('IN_STOCK', 'REVERSED')
  and not (s."Status" = 'RESERVED' and s."ReservedForOrderId" = trim(po."SourceOnlineOrderId"))
  and not (s."Status" = 'SOLD' and s."SoldOnlineOrderId" = trim(po."SourceOnlineOrderId"))
union all
-- Built for an open order, still In Stock and NOT reserved now: more built than the order still needs,
-- or the serial's item / variant doesn't match an order line - check and use Reserve for Order if needed.
select 'built for this order, still In Stock, not reserved', b.order_id, b."SerialNo"::text, b."ItemCode"::text, b.prod_order::text,
       b."Status"::text, 'variant ' || nullif(b.variant, '')
from built b
where b."Status" = 'IN_STOCK'
  and not exists (select 1 from reserved r where r.serial_no = b."SerialNo")
order by 1 desc, 2, 3;
