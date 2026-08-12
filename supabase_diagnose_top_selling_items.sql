-- One-off diagnostic for "Top Selling Items shows no sales" - per investigating why July 2026
-- returned empty. Run each block in the Supabase SQL editor and check the results; not meant to
-- be re-run automatically like the other supabase_*.sql files (no tables/functions created here).

-- 1) Does OnlineOrders (headers) actually have rows for the period in question?
select count(*) as order_count, min("Date") as earliest, max("Date") as latest
from public."OnlineOrders"
where "Date" >= '2026-07-01' and "Date" <= '2026-07-31';

-- 2) Of those, how many have a non-cancelled status (the report excludes Cancelled)?
select "Status", count(*) as order_count
from public."OnlineOrders"
where "Date" >= '2026-07-01' and "Date" <= '2026-07-31'
group by "Status"
order by order_count desc;

-- 3) The real question: does OnlineOrderLines have ANY rows at all for those orders?
select count(*) as line_count
from public."OnlineOrderLines" l
join public."OnlineOrders" o on o."OrderID" = l."OrderID"
where o."Date" >= '2026-07-01' and o."Date" <= '2026-07-31';

-- 4) Zoom out: does OnlineOrderLines have data for ANY period, and how fresh is it?
select count(*) as total_lines, min("SyncedAtUtc") as earliest_sync, max("SyncedAtUtc") as latest_sync
from public."OnlineOrderLines";

-- 5) Sanity check: total OnlineOrders rows vs. total distinct orders that have at least one line -
-- a big gap here confirms lines are only sparsely populated relative to headers.
select
  (select count(*) from public."OnlineOrders") as total_orders,
  (select count(distinct "OrderID") from public."OnlineOrderLines") as orders_with_lines;
