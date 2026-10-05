-- Payroll Spending report (docs/payroll-spending-report.html) - per "can you create me a new report
-- for my payroll.. i want to see how much im spending".
--
-- Reads the Payroll Ledger (PayrollLedgerEntries) only - so only FINALIZED runs count (a Draft run
-- posts nothing), plus Cash Advances on the day they're released. One row per ledger entry in the
-- date range; the page does all the grouping (employee / branch / month / pay run / component), so
-- switching views never re-queries.
--   - BasePay / Addition / Deduction / NetPay rows: dated by the run's PayDate (PeriodEnd if a run
--     somehow has no PayDate).
--   - CashAdvance rows: dated by the advance date (PayDate = AdvanceDate on these rows).
-- Funding / Payroll (company-level cash-on-hand) rows are left out - they'd double-count.
--
-- Branch / employee no. come from StaffUsers as they are now (the ledger doesn't snapshot them).
-- Super User or Payroll Officer (is_payroll_authorized, supabase_payroll_officer_access.sql).
--
-- Run AFTER supabase_payroll_ledger_funding_merge.sql. Safe to re-run.

drop function if exists public.admin_get_payroll_spending_report(text, text, date, date);

create or replace function public.admin_get_payroll_spending_report(
  p_admin_username text,
  p_admin_password text,
  p_date_from date,
  p_date_to date
)
returns table(
  pay_date date,
  run_id uuid,
  pay_cycle text,
  period_start date,
  period_end date,
  username text,
  display_name text,
  employee_no text,
  branch text,
  entry_type text,
  label text,
  amount numeric,
  method text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select coalesce(le."PayDate", le."PeriodEnd"),
           le."RunID",
           le."PayCycle"::text,
           le."PeriodStart",
           le."PeriodEnd",
           le."Username"::text,
           coalesce(nullif(trim(le."DisplayName"), ''), s."DisplayName", le."Username")::text,
           s."EmployeeNo"::text,
           nullif(trim(coalesce(s."WarehouseName", '')), '')::text,
           le."EntryType"::text,
           le."Label"::text,
           le."Amount",
           le."Method"::text
    from public."PayrollLedgerEntries" le
    left join public."StaffUsers" s on s."Username" = le."Username"
    where le."EntryType" in ('BasePay', 'Addition', 'Deduction', 'NetPay', 'CashAdvance')
      and coalesce(le."PayDate", le."PeriodEnd") between p_date_from and p_date_to
    order by coalesce(le."PayDate", le."PeriodEnd"), le."DisplayName", le."EntryType";
end;
$$;

grant execute on function public.admin_get_payroll_spending_report(text, text, date, date) to anon;
