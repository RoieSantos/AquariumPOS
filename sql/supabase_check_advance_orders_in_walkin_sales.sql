-- Read-only check - per "does walkin includes advance order?".
--
-- Do advance orders also show up in the walk-in / online sales (OnlineOrders), on top of their own
-- AdvanceOrders / AdvanceOrderPayments rows? Two suspected paths (see supabase_daily_sales_report.sql):
--   walkin_pay_in_full - POS Pay In Full writes a SALES receipt under the advance order's ReceiptNo, sent
--                        to the portal as a walk-in (PosReceiptNo = AdvanceOrders.ReceiptNo, same branch)
--   pancake_copy       - old advance orders pushed to Pancake ("Advance Order Ref:" note) and synced back
-- Last 90 days. 'summary' rows first, then up to 30 example rows per path. Safe to run any time.
with matches as (
  select 'walkin_pay_in_full'::text as path, o."OrderID", o."Date", w."Name" as branch, o."PosReceiptNo" as receipt,
         o."MoneyToCollect" as sale_total, a."TransactionNo" as advance_no, a."Date" as advance_date,
         a."NetAmount" as advance_value, coalesce(a."IsVoid", false) as advance_voided
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  join public."AdvanceOrders" a on a."ReceiptNo" = o."PosReceiptNo" and a."Warehouse" is not distinct from w."Name"
  where o."ReceivedAtShop" is true
    and o."Date" >= (now() at time zone 'Asia/Manila')::date - 90
    and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
  union all
  select 'pancake_copy', o."OrderID", o."Date", w."Name", substring(o."Note" from 'Advance Order Ref:\s*(\S+)'),
         o."MoneyToCollect", null, null, null, null
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where coalesce(o."Note", '') ilike '%Advance Order Ref:%'
    and o."Date" >= (now() at time zone 'Asia/Manila')::date - 90
    and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
),
ranked as (
  select m.*, row_number() over (partition by m.path order by m."Date" desc, m."OrderID") as rn
  from matches m
)
select 'summary' as section, path, count(*)::text as orders, to_char(coalesce(sum(sale_total), 0), 'FM999,999,990.00') as sale_total,
       min("Date")::text as first_date, max("Date")::text as last_date,
       null::text as branch, null::text as receipt, null::text as advance_no, null::text as detail
from matches
group by path
union all
select 'example', path, "OrderID", to_char(sale_total, 'FM999,999,990.00'), "Date"::text, null, branch, receipt, advance_no,
       case when path = 'walkin_pay_in_full'
            then concat('advance placed ', advance_date, ', value ', to_char(advance_value, 'FM999,999,990.00'),
                        case when advance_voided then ', VOIDED' else '' end)
       end
from ranked
where rn <= 30
order by 1 desc, 2, 5 desc;
