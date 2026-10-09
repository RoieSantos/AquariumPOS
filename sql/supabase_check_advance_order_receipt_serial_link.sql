-- Read-only pre-deploy check for supabase_advance_order_serials.sql: advance-order serials are linked by
-- ItemSerialTracking."SoldReceiptNo" = AdvanceOrders."ReceiptNo", so that receipt number must point at ONE
-- order. Expect 0 in every "problem" row; the "info" rows are just context.

select 'problem' as kind, 'advance orders sharing a ReceiptNo' as item,
       count(*)::text as detail
from (
  select "ReceiptNo" from public."AdvanceOrders"
  where nullif(trim("ReceiptNo"), '') is not null
  group by "ReceiptNo" having count(*) > 1
) d
union all
select 'problem', 'advance ReceiptNos also used as an online order sale (SoldOnlineOrderId set on its serials)',
       count(distinct s."SoldReceiptNo")::text
from public."ItemSerialTracking" s
join public."AdvanceOrders" a on a."ReceiptNo" = s."SoldReceiptNo"
where nullif(trim(s."SoldOnlineOrderId"), '') is not null
union all
select 'info', 'advance orders with no ReceiptNo (can''t take serials until resent from the POS)',
       count(*)::text
from public."AdvanceOrders" where nullif(trim("ReceiptNo"), '') is null
union all
select 'info', 'serials already tied to an advance order receipt (POS Pay In Full)',
       count(*)::text
from public."ItemSerialTracking" s
join public."AdvanceOrders" a on a."ReceiptNo" = s."SoldReceiptNo"
union all
select 'info', 'sample ReceiptNo values',
       (select string_agg("ReceiptNo", ', ') from (select "ReceiptNo" from public."AdvanceOrders"
         where nullif(trim("ReceiptNo"), '') is not null order by "SyncedAtUtc" desc nulls last limit 5) x);
