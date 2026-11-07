-- Read-only check: why Order Now order AO-00211 was pushed to Pancake (and isn't on the Online Orders New tab).
-- Since supabase_order_now_portal_only.sql, Order Now should save as 'Not Pushed' / UpdatedBy 'Order Now' and
-- never push - it waits on Online Orders -> New for Confirm Order. AO-00211 reached Pancake anyway, so this
-- checks the order itself and whether the LIVE functions still have the portal-only versions (re-running an
-- older file such as supabase_automated_order_drop_phone_fallback.sql would put the Pancake push back).
-- Safe to run any time. Ends with one result query.

select '1 AO-00211' as section,
       concat_ws(' | ',
         'Status=' || coalesce(o."Status", '(null)'),
         'Sync=' || coalesce(o."PancakeSyncStatus", '(null)'),
         'PancakeOrderId=' || coalesce(o."PancakeOrderId"::text, '-'),
         'SyncError=' || coalesce(o."PancakeSyncError", '-'),
         'UpdatedBy=' || coalesce(o."UpdatedBy", '(null)'),
         'MsgStatus=' || coalesce(o."ConfirmationMessageStatus", '(null)'),
         'Created=' || to_char(o."CreatedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'),
         'Customer=' || coalesce(o."CustomerName", ''),
         'Branch=' || coalesce(o."Location", ''),
         'Total=' || coalesce(o."EstimatedTotal", 0)::text) as detail
from public."AutomatedOrders" o
where o."OrderNo" = 'AO-00211'

union all
select '1 AO-00211', 'NOT FOUND'
where not exists (select 1 from public."AutomatedOrders" where "OrderNo" = 'AO-00211')

union all
select '2 AO-00211 lines', count(*)::text || ': ' || coalesce(string_agg(l."Quantity" || ' x ' || l."ItemName", ', ' order by l."EntryNo"), '-')
from public."AutomatedOrderLines" l
where l."OrderNo" = 'AO-00211'

union all
select '3 In Online Orders?',
       coalesce((select string_agg('Status=' || coalesce(oo."Status", ''), '; ')
                   from public."OnlineOrders" oo where oo."OrderID" = 'AO-00211'), 'no')

union all
select '4 LIVE submit_automated_order saves Not Pushed / Order Now (want true)',
       (pg_get_functiondef('public.submit_automated_order(text, text, text, text, text, text, text, text, text, jsonb)'::regprocedure)
          like '%''Order Now''%')::text

union all
select '5 LIVE public_sync_automated_order_to_pancake pushes to Pancake (want false)',
       (pg_get_functiondef('public.public_sync_automated_order_to_pancake(text)'::regprocedure)
          like '%_push_automated_order_to_pancake%')::text

union all
select '6 LIVE cron_process_pending_automated_orders pushes to Pancake (want false)',
       (pg_get_functiondef('public.cron_process_pending_automated_orders()'::regprocedure)
          like '%_push_automated_order_to_pancake%')::text

union all
select '7 Cron jobs touching AO orders / Pancake push',
       coalesce(string_agg(j.jobname || ' [' || j.schedule || ', active=' || j.active::text || ']: ' || left(j.command, 120), ' || '), 'none')
from cron.job j
where j.command ilike '%automated_order%' or j.command ilike '%pancake%'

union all
select '8 Order Now orders since 2026-10-28 by sync status',
       coalesce(string_agg(x, ', '), 'none')
from (
  select coalesce(o."PancakeSyncStatus", '(null)') || '=' || count(*) || ' (latest ' || max(o."OrderNo") || ')' as x
  from public."AutomatedOrders" o
  where o."CreatedAtUtc" >= '2026-10-28'
    and coalesce(o."UpdatedBy", '') = 'Order Now'
  group by o."PancakeSyncStatus"
) t

union all
select '9 Last 8 AO orders', string_agg(x, ' || ')
from (
  select o."OrderNo" || ' ' || coalesce(o."Status", '') || '/' || coalesce(o."PancakeSyncStatus", '')
         || ' pc=' || coalesce(o."PancakeOrderId"::text, '-') || ' by ' || coalesce(o."UpdatedBy", '') as x
  from public."AutomatedOrders" o
  order by o."CreatedAtUtc" desc
  limit 8
) t;
