-- READ-ONLY check: are Xendit salary payouts (Payroll Run) and Xendit cash advances (Timesheets) installed?
-- Covers supabase_xendit_payroll_payouts.sql and supabase_xendit_cash_advance_payouts.sql. Changes nothing.
-- Every row should say OK; anything else names the file to run. Ends with ONE result.

select 'salary: payout columns' as section,
       case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'StaffUsers'
                  and column_name in ('PayViaXendit', 'PayoutChannelCode', 'PayoutChannelName', 'PayoutAccountNumber', 'PayoutAccountName')) = 5
            then 'OK' else 'MISSING - run supabase_xendit_payroll_payouts.sql' end as value
union all
select 'salary: XenditPayouts table',
       case when to_regclass('public."XenditPayouts"') is not null then 'OK' else 'MISSING - run supabase_xendit_payroll_payouts.sql' end
union all
select 'salary: finalize knows Xendit lines',
       case when to_regprocedure('public.admin_finalize_payroll_run(text, text, uuid)') is not null
             and pg_get_functiondef('public.admin_finalize_payroll_run(text, text, uuid)'::regprocedure) like '%Payroll Payout (Xendit)%'
            then 'OK' else 'OLD - run supabase_xendit_payroll_payouts.sql' end
union all
select 'salary: send helpers',
       case when to_regprocedure('public._payroll_payouts_prepare(uuid, boolean, text, uuid[])') is not null
             and to_regprocedure('public.admin_list_payroll_run_payouts(text, text, uuid)') is not null
            then 'OK' else 'MISSING - run supabase_xendit_payroll_payouts.sql' end
union all
select 'advance: Pending status',
       case when coalesce(pg_get_constraintdef((select oid from pg_constraint where conname = 'CK_PayrollCashAdvances_Status')), '') like '%Pending%'
            then 'OK' else 'MISSING - run supabase_xendit_cash_advance_payouts.sql' end
union all
select 'advance: Xendit method',
       case when coalesce(pg_get_constraintdef((select oid from pg_constraint where conname = 'CK_PayrollCashAdvances_Method')), '') like '%Xendit%'
            then 'OK' else 'MISSING - run supabase_xendit_cash_advance_payouts.sql' end
union all
select 'advance: XenditPayouts takes advances',
       case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'XenditPayouts' and column_name = 'AdvanceID')
            then 'OK' else 'MISSING - run supabase_xendit_cash_advance_payouts.sql' end
union all
select 'advance: Timesheets save knows Xendit',
       case when to_regprocedure('public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb)') is not null
             and pg_get_functiondef('public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb)'::regprocedure) like '%_cash_advance_payout_locked%'
            then 'OK' else 'OLD - run supabase_xendit_cash_advance_payouts.sql' end
union all
select 'advance: approval + send helpers',
       case when to_regprocedure('public.admin_submit_cash_advances(text, text, uuid[])') is not null
             and to_regprocedure('public._advance_payouts_prepare(boolean, text, uuid[])') is not null
             and to_regprocedure('public.admin_list_payroll_payout_flags(text, text)') is not null
            then 'OK' else 'MISSING - run supabase_xendit_cash_advance_payouts.sql' end
union all
select 'advance: paid advance turns Outstanding',
       case when to_regprocedure('public._payroll_payout_record(uuid, text, text, text, text, text, timestamptz, jsonb)') is not null
             and pg_get_functiondef('public._payroll_payout_record(uuid, text, text, text, text, text, timestamptz, jsonb)'::regprocedure) like '%PayrollCashAdvances%'
            then 'OK' else 'OLD - run supabase_xendit_cash_advance_payouts.sql' end
union all
select 'info: employees set to pay via Xendit',
       case when exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'StaffUsers' and column_name = 'PayViaXendit')
            then (xpath('/row/n/text()', query_to_xml('select count(*) as n from public."StaffUsers" where "PayViaXendit"', false, false, '')))[1]::text
            else 'n/a' end;
