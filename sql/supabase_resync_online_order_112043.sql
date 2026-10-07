-- Re-pull online order 112043 (and every other order Pancake changed in the last day) into the portal,
-- then show whether it landed - per "check why online order id 112043 is not yet in the portal".
--
-- FINDINGS so far (supabase_check_online_order_112043*.sql): Pancake HAS the order - status "printed",
-- received_at_shop=false - so none of the sync's skip rules (status New / walk-in flag) apply, yet
-- public."OnlineOrders" has no row for it.
--
-- LIKELY CAUSE: the every-minute cron_sync_online_orders_from_pancake (supabase_walkin_order_pos_note.sql)
-- advances its PancakeSyncState cursor to the newest updated_at it SEES, before saving each order, and a
-- failed save is swallowed ("exception when others then null"). So one failed upsert (e.g. a statement
-- timeout while a staff edit held the row lock - see supabase_online_order_sync_no_long_locks.sql, or a
-- value too long for its column) loses that order until someone edits it in Pancake again.
--
-- WHAT THIS DOES (same idea as supabase_online_orders_full_resync.sql - upserts only, nothing deleted or
-- duplicated, cursor only moves forward again from where it's set):
--   1. Rewinds the cursor 1 day - ONLY while 112043 is still missing, so re-running this to check
--      progress doesn't keep re-rewinding once it has landed.
--   2. ONE result: did 112043 land, would any of its Pancake values overflow a column (a save that would
--      fail every time), the last cron runs' status, and where the cursor is.
-- The every-minute cron job does the actual re-pull (it has no time limit). Running the sync inline here
-- was cancelled by the SQL editor's statement timeout ("HTTP request cancelled") - and since the editor
-- runs the whole script as one transaction, that also rolled back the rewind.
--
-- HOW TO USE: run once, wait ~2 minutes, run again. Safe to re-run.

-- 1.
update public."PancakeSyncState"
set "LastSyncUtc" = least("LastSyncUtc", now() - interval '1 day')
where "Entity" = '/orders'
  and not exists (select 1 from public."OnlineOrders" where "OrderID" = '112043');

-- 2.
with
t as (
  select extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000') is not null as ok
),
s as (
  select r.status as http_status, r.content
  from t, lateral extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders?api_key='
                           || public._pancake_api_key() || '&search=112043&page_size=30&page=1'
                           || case when t.ok then '' else '' end) r
),
e as (
  select x as j
  from s, jsonb_array_elements(case when s.http_status between 200 and 299
                                         and jsonb_typeof(s.content::jsonb -> 'data') = 'array'
                                    then s.content::jsonb -> 'data' else '[]'::jsonb end) x
  where coalesce(x ->> 'receipt_no', x ->> 'id') = '112043'
),
f as (  -- same field picks as the cron's header upsert, with each target column's size limit
  select v.field, v.val, v.max_len
  from e, lateral (values
    ('CustomerName', coalesce(nullif(trim(j -> 'shipping_address' ->> 'full_name'), ''), nullif(trim(j ->> 'bill_full_name'), ''),
                              j -> 'customer' ->> 'name'), 200),
    ('ShippingAddress', coalesce(j -> 'shipping_address' ->> 'full_address', j -> 'shipping_address' ->> 'address',
                                 j ->> 'full_address'), 1000),
    ('ShippingPhone', coalesce(j -> 'shipping_address' ->> 'phone_number', j ->> 'phone_number', j ->> 'bill_phone_number',
                               j -> 'customer' ->> 'phone_number'), 50),
    ('Page_ID', coalesce(j ->> 'page_id', j ->> 'pageId'), 200),
    ('Conversation_ID', coalesce(j ->> 'conversation_id', j ->> 'conversationId'), 200),
    ('LocationID', coalesce(j ->> 'warehouse_id', j ->> 'warehouseId'), 200),
    ('updated_at (Pancake)', j ->> 'updated_at', null),
    ('inserted_at (Pancake)', j ->> 'inserted_at', null)
  ) v(field, val, max_len)
)
select '1 portal row after re-pull' as section,
       coalesce(max(o."OrderID"), 'STILL MISSING') as item,
       coalesce(max(concat_ws(' | ', 'Status=' || o."Status", 'Date=' || o."Date",
                              'Customer=' || o."CustomerName", 'SyncedAtUtc=' || o."SyncedAtUtc")),
                'save is failing for this order - see section 2 for a too-long value, section 3 for cron errors') as detail
from public."OnlineOrders" o
where o."OrderID" = '112043'

union all
select '2 Pancake value sizes', f.field,
       case when f.max_len is not null and length(f.val) > f.max_len
              then 'TOO LONG - ' || length(f.val) || ' chars, column allows ' || f.max_len || ': ' || left(f.val, 120)
            else coalesce(length(f.val)::text || ' chars', 'null')
                 || case when f.max_len is null then ': ' || coalesce(f.val, '') else ' (ok, max ' || f.max_len || ')' end
       end
from f

union all
select '2 Pancake value sizes', 'HTTP ' || s.http_status, 'NOT FOUND in Pancake search - ' || left(coalesce(s.content, ''), 150)
from s
where not exists (select 1 from e)

union all
select '3 recent cron runs', to_char(d.start_time at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI:SS'),
       j.jobname || ' | ' || d.status || ' | ' || left(coalesce(d.return_message, ''), 150)
from (select * from cron.job_run_details order by start_time desc limit 200) d
join cron.job j on j.jobid = d.jobid
where j.jobname = 'sync-online-orders-from-pancake'
  and d.start_time > now() - interval '15 minutes'

union all
select '4 cursor now', "Entity", 'LastSyncUtc=' || coalesce("LastSyncUtc"::text, 'null')
from public."PancakeSyncState" where "Entity" = '/orders'

order by 1, 2 desc;
