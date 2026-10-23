-- READ-ONLY check: is anything still coming in through Pancake? Decides whether the Pancake sync crons
-- (the bulk of the Disk IO use - see supabase_diagnose_disk_io.sql) can be stopped.
--
-- Changes nothing. One result: section / item / detail.
--   1 Orders per day   - last 14 days: orders that came from Pancake vs portal-only orders (Source 'Portal')
--   2 Order Now        - website Order Now orders (AutomatedOrders) last 14 days by Pancake push status
--   3 Newest Pancake   - the most recent Pancake order and when the sync last touched one
--   4 Open Pancake     - Pancake orders from the last 90 days by status (still moving = still worked in Pancake)
--   5 Recent orders    - every order of the last 3 days: Pancake or portal, in-store or not, branch

select '1 Orders per day' as section, d::date::text as item,
       'Pancake ' || count(o."OrderID") filter (where coalesce(o."Source", '') <> 'Portal')
       || ' / portal ' || count(o."OrderID") filter (where o."Source" = 'Portal') as detail
from generate_series(current_date - 13, current_date, interval '1 day') d
left join public."OnlineOrders" o on o."Date" = d::date
group by d

union all
select '2 Order Now', coalesce("PancakeSyncStatus", '(null)'),
       count(*) || ' orders; newest ' || max("CreatedAtUtc")::text
from public."AutomatedOrders"
where "CreatedAtUtc" > now() - interval '14 days'
group by "PancakeSyncStatus"

union all
select '3 Newest Pancake', 'newest Pancake order date',
       coalesce(max("Date")::text, 'none')
from public."OnlineOrders" where coalesce("Source", '') <> 'Portal'
union all
select '3 Newest Pancake', 'last Pancake change seen (Last_Updated_At)',
       coalesce(max("Last_Updated_At")::text, 'none')
from public."OnlineOrders" where coalesce("Source", '') <> 'Portal'

union all
select '4 Open Pancake', coalesce("Status", '(null)'),
       count(*) || ' orders; last changed in Pancake ' || coalesce(max("Last_Updated_At")::text, '?')
from public."OnlineOrders"
where coalesce("Source", '') <> 'Portal' and "Date" > current_date - 90
group by "Status"

-- Every Pancake order dated in the last 3 days, and the portal walk-ins (WI-) beside them: in-store
-- (ReceivedAtShop) from a store PC still on the old POS build, or real online orders typed in Pancake?
union all
select '5 Recent orders', o."Date"::text || ' ' || coalesce(o."Time", '') || ' ' || o."OrderID",
       case when coalesce(o."Source", '') = 'Portal' then 'PORTAL' else 'PANCAKE' end
       || '; in-store ' || coalesce(o."ReceivedAtShop"::text, '?')
       || '; ' || coalesce(o."Status", '?') || '; branch ' || coalesce(o."LocationID", '?')
       || '; ' || coalesce(o."CustomerName", '?') || '; total ' || coalesce(o."MoneyToCollect"::text, '?')
from public."OnlineOrders" o
where o."Date" >= current_date - 2

order by 1, 2;
