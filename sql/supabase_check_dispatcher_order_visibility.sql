-- Read-only check: why isn't online order 114426 (GMA, To Ship, Custom) showing for a Dispatcher?
-- Per "this order has badge but its not showing for dispatchers view".
--
-- A Dispatcher's list (admin_list_online_orders, latest in supabase_online_orders_confirmed_date.sql)
-- shows a To Ship order only when ALL of these hold:
--   1. the user has the 'Dispatcher' staff role
--   2. the order's Status is To Ship / Packing / Packed
--   3. the user has NO warehouse, or StaffUsers.WarehouseName = the order's Warehouses.Name EXACTLY
-- This lists the order, every Dispatcher with a yes/no per rule, and whether the live list function
-- still has the Dispatcher rule (an older SQL file re-run later could have replaced it).
-- Change the order id below to check another order. Safe to run any time - changes nothing.

with ord as (
  select o."OrderID", o."Status", o."LocationID", w."Name" as warehouse_name, o."ReceivedAtShop"
  from public."OnlineOrders" o
  left join public."Warehouses" w on w."ID" = o."LocationID"
  where o."OrderID" = '114426'
)
select 'order' as section,
       ord."OrderID"::text as name,
       format('status=%s | warehouse=%s (id %s) | walk-in=%s',
              coalesce(ord."Status", '?'), coalesce('"' || ord.warehouse_name || '"', 'NONE - LocationID not in Warehouses'),
              coalesce(ord."LocationID", '?'), coalesce(ord."ReceivedAtShop"::text, 'false')) as detail
from ord
union all
select 'dispatcher',
       s."Username"::text,
       format('active=%s | warehouse=%s | status ok=%s | warehouse ok=%s | => %s',
              coalesce(to_jsonb(s) ->> 'IsActive', to_jsonb(s) ->> 'Active', '?'),
              coalesce('"' || nullif(trim(coalesce(s."WarehouseName", '')), '') || '"', 'none (sees all branches)'),
              lower(trim(coalesce(ord."Status", ''))) in ('to ship', 'packing', 'packed'),
              nullif(trim(coalesce(s."WarehouseName", '')), '') is null or ord.warehouse_name = nullif(trim(coalesce(s."WarehouseName", '')), ''),
              case when lower(trim(coalesce(ord."Status", ''))) in ('to ship', 'packing', 'packed')
                    and (nullif(trim(coalesce(s."WarehouseName", '')), '') is null or ord.warehouse_name = nullif(trim(coalesce(s."WarehouseName", '')), ''))
                   then 'SHOULD SEE IT' else 'HIDDEN' end)
from public."StaffUsers" s
cross join ord
where 'Dispatcher' = any(coalesce(s."StaffRoles", '{}'))
union all
select 'live list function',
       'admin_list_online_orders',
       case when bool_or(pg_get_functiondef(p.oid) ilike '%v_is_dispatcher%')
            then 'has the Dispatcher To Ship rule'
            else 'MISSING the Dispatcher rule - an older SQL file replaced it' end
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_list_online_orders'
order by 1, 2;
