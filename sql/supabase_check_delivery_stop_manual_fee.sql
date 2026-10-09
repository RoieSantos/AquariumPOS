-- Read-only check: why a manual Delivery Fee typed on the delivery calendar's "Edit Details" doesn't stick.
-- Looks at what supabase_delivery_stop_manual_fee.sql should have set up, and the latest stops' fees.
-- Expect: column = ok, ONE save function whose args end in "p_delivery_fee numeric", list/receipt
-- functions that return delivery_fee, and your test stop under "recent stop" with its manual fee.

select 'column' as section, 'DeliveryStops.ManualDeliveryFee' as item,
       case when exists (select 1 from information_schema.columns
                         where table_schema = 'public' and table_name = 'DeliveryStops' and column_name = 'ManualDeliveryFee')
            then 'ok' else 'MISSING - run supabase_delivery_stop_manual_fee.sql' end as detail
union all
select 'save function', p.proname::text, pg_get_function_identity_arguments(p.oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_update_delivery_stop_geocode'
union all
select 'returns fee?', p.proname::text,
       case when pg_get_function_result(p.oid) like '%is_manual_delivery_fee%' or pg_get_function_result(p.oid) like '%delivery_fee%'
            then 'yes' else 'NO - an older file overwrote it; re-run supabase_delivery_stop_manual_fee.sql' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('admin_list_delivery_stops', 'admin_get_delivery_receipt')
union all
select 'recent stop', coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo") || ' (' || s."DeliveryDate" || ')',
       'manual fee = ' || coalesce(to_jsonb(s) ->> 'ManualDeliveryFee', '(blank)')
from (select * from public."DeliveryStops" order by "DeliveryDate" desc limit 15) s;
