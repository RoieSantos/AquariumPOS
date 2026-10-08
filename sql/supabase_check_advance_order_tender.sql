-- Read-only check: why the Dashboard's "Today's Advance Orders" card shows no "Collected today ·
-- by tender" list. Run the whole file; one result grid, one row per check.
--   1_table_exists     - no  => supabase_advance_order_payments.sql hasn't been run
--   2_function_exists  - no  => same
--   3_payments_today   - 0   => the updated POS build hasn't uploaded anything yet (not installed /
--                               not restarted, or its 5-minute sync hasn't ticked)
--   4_payments_total   - 0   => no POS terminal has ever uploaded an advance-order payment
--   5_latest_upload    - when the last payment row arrived (SyncedAtUtc, Manila time)
--   6_today_orders     - today's advance orders and whether each has payment rows

select '1_table_exists' as section,
       case when to_regclass('public."AdvanceOrderPayments"') is not null then 'yes' else 'no' end as result
union all
select '2_function_exists',
       case when to_regprocedure('public.admin_get_dashboard_daily_advance_tender(text, text, text)') is not null then 'yes' else 'no' end
union all
select '3_payments_today',
       case when to_regclass('public."AdvanceOrderPayments"') is null then 'n/a (no table)'
            else (xpath('/row/c/text()', query_to_xml(
                   'select count(*) as c from public."AdvanceOrderPayments" where "Date" = (now() at time zone ''Asia/Manila'')::date',
                   false, true, '')))[1]::text end
union all
select '4_payments_total',
       case when to_regclass('public."AdvanceOrderPayments"') is null then 'n/a (no table)'
            else (xpath('/row/c/text()', query_to_xml(
                   'select count(*) as c from public."AdvanceOrderPayments"', false, true, '')))[1]::text end
union all
select '5_latest_upload',
       case when to_regclass('public."AdvanceOrderPayments"') is null then 'n/a (no table)'
            else coalesce((xpath('/row/c/text()', query_to_xml(
                   'select max("SyncedAtUtc" at time zone ''Asia/Manila'') as c from public."AdvanceOrderPayments"',
                   false, true, '')))[1]::text, 'never') end
union all
select '6_today_orders',
       a."TransactionNo" || ' · receipt ' || coalesce(a."ReceiptNo", '?') || ' · ' || coalesce(a."Warehouse", '?')
         || ' · downpayment ' || coalesce(a."Downpayment", 0)::text
         || ' · payment rows: ' ||
         case when to_regclass('public."AdvanceOrderPayments"') is null then 'n/a'
              else (xpath('/row/c/text()', query_to_xml(
                     format('select count(*) as c from public."AdvanceOrderPayments" where "AdvanceTransactionNo" = %L', a."TransactionNo"),
                     false, true, '')))[1]::text end
from public."AdvanceOrders" a
where a."Date" = (now() at time zone 'Asia/Manila')::date;
