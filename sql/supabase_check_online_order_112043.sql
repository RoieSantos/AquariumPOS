-- Read-only check: why online order 112043 isn't showing in the portal's Online Orders page.
-- Known reasons an order never lands in / is hidden from public."OnlineOrders":
--   a. Pancake status is "New" - all three sync paths (desktop SyncOrderListAsync, cron/"Sync from
--      Pancake", browse-time upsert) skip "New" orders (see supabase_manual_insert_online_order_91120.sql).
--   b. Pancake received_at_shop = true -> synced as a Walk-In and hidden from the normal Online list
--      (shows under Walk-In instead); missing/odd received_at_shop -> skipped entirely.
--   c. Row exists but the list filters hide it (branch scope / status tab / Date).
--   d. It's a GMA/Order Now order whose Pancake push failed, so Pancake never got it at all.
--
-- Section 5 calls Pancake live (one HTTP GET). Safe to run any time. ONE result.

with pk as (
  select r.status as http_status,
         case when r.status between 200 and 299 then
           coalesce(case when jsonb_typeof(r.content::jsonb -> 'data') = 'object' then r.content::jsonb -> 'data' end,
                    r.content::jsonb)
         end as o,
         left(r.content, 300) as raw
  from extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders/112043?api_key='
                           || public._pancake_api_key()) r
)
select '1 OnlineOrders row' as section,
       coalesce(max(o."OrderID"), 'MISSING') as item,
       coalesce(max(concat_ws(' | ',
         'Status=' || o."Status", 'Date=' || o."Date", 'ReceivedAtShop=' || coalesce(o."ReceivedAtShop"::text, 'null'),
         'LocationID=' || coalesce(o."LocationID", 'null'), 'Warehouse=' || coalesce(w."Name", '(no match)'),
         'CreatedBy=' || coalesce(o."CreatedBy", 'null'), 'LastUpdated=' || o."Last_Updated_At",
         'SyncedAtUtc=' || o."SyncedAtUtc")),
         'PROBLEM - never synced from Pancake (see section 5 for why)') as detail
from public."OnlineOrders" o
left join public."Warehouses" w on w."ID" = o."LocationID"
where o."OrderID" = '112043'

union all
select '2 OnlineOrderLines', count(*)::text, string_agg(coalesce("ItemCode", '') || ' x' || coalesce("Quantity"::text, '?'), '; ')
from public."OnlineOrderLines" where "OrderID" = '112043'

union all
select '3 AutomatedOrders (GMA/Order Now)', ao."OrderNo",
       concat_ws(' | ', 'Status=' || ao."Status", 'PancakeSync=' || ao."PancakeSyncStatus",
                 'PancakeReceiptNo=' || coalesce(ao."PancakeReceiptNo", 'null'),
                 'Created=' || ao."CreatedAtUtc", 'Error=' || coalesce(ao."PancakeSyncError", '-'))
from public."AutomatedOrders" ao
where ao."PancakeReceiptNo" = '112043' or ao."OrderNo" ilike '%112043%'

union all
select '4 /orders sync cursor', "Entity", 'LastSyncUtc=' || coalesce("LastSyncUtc"::text, 'null')
from public."PancakeSyncState" where "Entity" = '/orders'

union all
select '5 Pancake live', 'HTTP ' || pk.http_status,
       case when pk.o is null then 'Not found / error: ' || coalesce(pk.raw, '')
            else concat_ws(' | ',
              'status=' || coalesce(pk.o ->> 'status', 'null'),
              'status_name=' || coalesce(pk.o ->> 'status_name', 'null'),
              'received_at_shop=' || coalesce(pk.o ->> 'received_at_shop', 'null'),
              'warehouse_id=' || coalesce(pk.o ->> 'warehouse_id', 'null'),
              'inserted_at=' || coalesce(pk.o ->> 'inserted_at', 'null'),
              'updated_at=' || coalesce(pk.o ->> 'updated_at', 'null'),
              'customer=' || coalesce(pk.o -> 'shipping_address' ->> 'full_name', pk.o ->> 'bill_full_name', 'null'))
       end
from pk

order by 1, 2;
