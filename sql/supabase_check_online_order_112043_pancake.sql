-- Read-only follow-up to supabase_check_online_order_112043.sql: Pancake answered HTTP 500 on
-- GET /orders/112043, so this searches Pancake's order LIST instead and compares the newest orders
-- on both sides - tells us whether 112043 exists in Pancake (and its status / received_at_shop) and
-- whether the portal's sync is keeping up at all.
--
-- Makes 2 HTTP calls to Pancake. Safe to run any time. ONE result.
--
-- The http extension's default timeout is 5s, which a Pancake list search can exceed ("Operation
-- timed out after 5001 milliseconds"). Raised to 30s here the same way the sync functions do; the
-- lateral reference to t.ok forces the timeout to be set BEFORE each http_get runs.

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
n as (
  select r.status as http_status, r.content
  from t, lateral extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders?api_key='
                           || public._pancake_api_key() || '&page_size=8&page=1'
                           || case when t.ok then '' else '' end) r
),
s_items as (
  select e
  from s, jsonb_array_elements(case when s.http_status between 200 and 299
                                         and jsonb_typeof(s.content::jsonb -> 'data') = 'array'
                                    then s.content::jsonb -> 'data' else '[]'::jsonb end) e
),
n_items as (
  select e
  from n, jsonb_array_elements(case when n.http_status between 200 and 299
                                         and jsonb_typeof(n.content::jsonb -> 'data') = 'array'
                                    then n.content::jsonb -> 'data' else '[]'::jsonb end) e
)
select '0 now' as section, now()::text as item, 'compare with the sync times below' as detail

union all
select '1 Pancake search 112043', coalesce(e ->> 'id', '?'),
       concat_ws(' | ',
         'status=' || coalesce(e ->> 'status', 'null'),
         'status_name=' || coalesce(e ->> 'status_name', 'null'),
         'received_at_shop=' || coalesce(e ->> 'received_at_shop', 'null'),
         'warehouse_id=' || coalesce(e ->> 'warehouse_id', 'null'),
         'inserted_at=' || coalesce(e ->> 'inserted_at', 'null'),
         'updated_at=' || coalesce(e ->> 'updated_at', 'null'),
         'customer=' || coalesce(e ->> 'bill_full_name', e -> 'shipping_address' ->> 'full_name', 'null'))
from s_items

union all
select '1 Pancake search 112043', 'HTTP ' || s.http_status,
       'NO MATCH - ' || left(coalesce(s.content, ''), 200)
from s
where not exists (select 1 from s_items)

union all
select '2 Pancake newest', coalesce(e ->> 'id', '?'),
       concat_ws(' | ',
         'status_name=' || coalesce(e ->> 'status_name', e ->> 'status', 'null'),
         'received_at_shop=' || coalesce(e ->> 'received_at_shop', 'null'),
         'inserted_at=' || coalesce(e ->> 'inserted_at', 'null'))
from n_items

union all
select '2 Pancake newest', 'HTTP ' || n.http_status, 'ERROR - ' || left(coalesce(n.content, ''), 200)
from n
where not exists (select 1 from n_items)

union all
select '3 Portal newest', max("OrderID"),
       'highest numeric OrderID | newest SyncedAtUtc=' || max("SyncedAtUtc")::text
       || ' | synced in last 2h=' || count(*) filter (where "SyncedAtUtc" > now() - interval '2 hours')
from public."OnlineOrders"
where "OrderID" ~ '^\d+$' and length("OrderID") = (select max(length("OrderID")) from public."OnlineOrders" where "OrderID" ~ '^\d+$')

order by 1, 2;
