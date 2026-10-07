-- Unstick the every-minute Pancake -> Online Orders header sync - per "check why online order id 112043
-- is not yet in the portal".
--
-- CAUSE: since ~10:46 AM (Manila) 2026-10-07 every run of the 'sync-online-orders-from-pancake' cron job
-- failed with "HTTP request cancelled" / "canceling statement due to statement timeout" - each run was
-- cut off by the role's statement timeout (~2 min) while still walking Pancake's /orders pages (Pancake
-- has been slow today: 5s timeouts and HTTP 500s seen during the 112043 checks). A cancelled run rolls
-- back everything, including the PancakeSyncState cursor, so every next run re-walked the same backlog
-- and timed out again - NO new/changed online order reached the portal after 10:46, 112043 included
-- (Pancake updated it at 03:04 UTC = 11:04 AM). The 1-day rewind in supabase_resync_online_order_112043.sql
-- made each run bigger still - undone in step 1.
--
-- FIX:
--   1. Cursor back to 02:40 UTC (10:40 AM Manila) - just before the last successful sync (02:46 UTC) -
--      only if it's currently earlier (i.e. undoes the 1-day rewind; never moves it backward).
--   2. Reschedule the job with its own 5-minute statement timeout (pg_cron never overlaps runs of the
--      same job, so a slow run just delays the next one instead of piling up).
--   3. ONE result: the job's new command, cursor, recent runs, a timed probe of one Pancake page (is
--      Pancake slow / does it honor the updated_after filter?), and whether 112043 has landed.
--
-- Upserts/scheduling only - safe to re-run. Run once, wait ~3 minutes, run again to watch progress.
-- Do NOT re-run supabase_resync_online_order_112043.sql - it would rewind the cursor a day again.

-- 1.
update public."PancakeSyncState"
set "LastSyncUtc" = '2026-10-07 02:40:00+00'
where "Entity" = '/orders'
  and "LastSyncUtc" < '2026-10-07 02:40:00+00';

-- 2.
do $$
begin
  perform cron.unschedule('sync-online-orders-from-pancake');
exception when others then null;
end;
$$;
select cron.schedule('sync-online-orders-from-pancake', '* * * * *',
  $$set statement_timeout = '5min'; select public.cron_sync_online_orders_from_pancake(100, 100, 0, 0);$$);

-- 3.
with
c as (
  select "LastSyncUtc" from public."PancakeSyncState" where "Entity" = '/orders'
),
t0 as materialized (
  select clock_timestamp() as started,
         extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '60000') is not null as ok
),
p as materialized (
  select r.status as http_status, r.content, clock_timestamp() - t0.started as took
  from t0, c, lateral extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders?api_key='
         || public._pancake_api_key() || '&page_size=100&page=1'
         || '&updated_after=' || to_char(c."LastSyncUtc" at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
         || case when t0.ok then '' else '' end) r
),
pj as (
  select p.*, case when p.http_status between 200 and 299 then p.content::jsonb end as b from p
)
select '1 job command' as section, j.jobname as item, j.schedule || ' | ' || j.command as detail
from cron.job j where j.jobname = 'sync-online-orders-from-pancake'

union all
select '2 cursor', '/orders', 'LastSyncUtc=' || "LastSyncUtc" || ' (Manila ' || ("LastSyncUtc" at time zone 'Asia/Manila')::text || ')'
from c

union all
select '3 recent runs', to_char(d.start_time at time zone 'Asia/Manila', 'HH24:MI:SS'),
       d.status || ' | took ' || coalesce(to_char(d.end_time - d.start_time, 'MI:SS'), 'still running')
       || ' | ' || left(coalesce(d.return_message, ''), 120)
from (select * from cron.job_run_details order by start_time desc limit 200) d
join cron.job j on j.jobid = d.jobid
where j.jobname = 'sync-online-orders-from-pancake'
  and d.start_time > now() - interval '10 minutes'

union all
select '4 Pancake page probe', 'HTTP ' || pj.http_status || ' in ' || to_char(extract(epoch from pj.took), 'FM990.0') || 's',
       case when pj.b is null then 'ERROR - ' || left(coalesce(pj.content, ''), 150)
            else concat_ws(' | ',
              'items on page=' || coalesce(jsonb_array_length(pj.b -> 'data'), 0),
              'total_entries=' || coalesce(pj.b ->> 'total_entries', pj.b ->> 'total', '?'),
              'total_pages=' || coalesce(pj.b ->> 'total_pages', '?'),
              'oldest updated_at on page=' || coalesce((select min(x ->> 'updated_at') from jsonb_array_elements(pj.b -> 'data') x), '?'))
       end
from pj

union all
select '5 order 112043', coalesce(max(o."OrderID"), 'not yet'),
       coalesce(max('Status=' || o."Status" || ' | Customer=' || o."CustomerName" || ' | SyncedAtUtc=' || o."SyncedAtUtc"),
                'waiting for a successful run (section 3)')
from public."OnlineOrders" o where o."OrderID" = '112043'

order by 1, 2 desc;
