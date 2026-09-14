-- Dashboard "Payroll This Month" card, per "after the finalize payroll run i want to show it
-- here .. so I can track how much is the salary spent for this month." Sums the NetPay rows
-- already posted to PayrollLedgerEntries at Finalize time (supabase_payroll_ledger.sql/
-- supabase_payroll_ledger_funding_merge.sql) - NetPay is take-home pay (BasePay + Additions -
-- Deductions), so summing just that EntryType gives total money actually paid to employees,
-- without double-counting the BasePay/Addition/Deduction rows also posted for the same run.
-- Filtered by PayDate falling in the current calendar month (Asia/Manila, same boundary
-- convention as admin_get_expense_entry_summary/admin_get_online_order_financial_summary) - a
-- Draft run contributes nothing, since ledger rows only exist once Finalized.
--
-- Uses is_payroll_authorized (Super User OR Payroll Officer - supabase_payroll_officer_access.sql)
-- rather than is_admin_authorized, so a Payroll Officer without full Super User can see this too.
--
-- Run this AFTER supabase_payroll_ledger_funding_merge.sql.

create or replace function public.admin_get_payroll_month_summary(p_admin_username text, p_admin_password text)
returns table(month_payroll numeric, month_payroll_employee_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  return query
    select
      coalesce(sum("Amount"), 0)::numeric,
      count(distinct "Username")::int
    from public."PayrollLedgerEntries"
    where "EntryType" = 'NetPay'
      and "PayDate" >= v_month_start and "PayDate" < v_month_end;
end;
$$;

grant execute on function public.admin_get_payroll_month_summary(text, text) to anon;
