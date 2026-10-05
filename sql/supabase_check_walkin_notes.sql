-- Read-only check: why the Walk-in Orders list shows no POS Description / Print Note.
-- Is the "Note" sync installed (supabase_walkin_order_pos_note.sql), and do recent walk-ins have a
-- POS note / print note saved? One result set (section / detail).

select 'note column exists' as section,
       exists(select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'OnlineOrders' and column_name = 'Note')::text as detail
union all
select 'staff_get_online_order_notes exists',
       exists(select 1 from pg_proc where proname = 'staff_get_online_order_notes')::text
union all
select 'cron sync saves Note',
       coalesce((select (pg_get_functiondef(p.oid) like '%v_note := nullif(trim(coalesce(v_item ->> ''note''%')::text
                 from pg_proc p where p.proname = 'cron_sync_online_orders_from_pancake' limit 1), 'function missing')
union all
select 'walk-ins last 7 days', count(*)::text
from public."OnlineOrders" where "ReceivedAtShop" is true and "Date" >= current_date - 7
union all
select 'walk-ins last 7 days with Note', count(*)::text
from public."OnlineOrders" where "ReceivedAtShop" is true and "Date" >= current_date - 7
  and nullif(trim(coalesce(to_jsonb("OnlineOrders") ->> 'Note', '')), '') is not null
union all
select 'walk-ins last 7 days with NotePrint', count(*)::text
from public."OnlineOrders" where "ReceivedAtShop" is true and "Date" >= current_date - 7
  and nullif(trim(coalesce("NotePrint", '')), '') is not null
union all
select 'sample walk-in ' || "OrderID",
       coalesce(left(to_jsonb(o) ->> 'Note', 150), '(no Note)') || '  ||  print: ' || coalesce(left("NotePrint", 80), '(none)')
from (select * from public."OnlineOrders" where "ReceivedAtShop" is true
      order by "Date" desc nulls last, "Time" desc nulls last limit 5) o;
