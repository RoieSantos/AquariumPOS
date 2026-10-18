-- admin_list_payroll_run_lines: add payment_method so the Payroll Run page's Lines grid can show
-- whether each employee is paid Cash or Digital.
--
-- Same rule as admin_get_payroll_run_funding_requirement / admin_finalize_payroll_run
-- (supabase_payroll_funding_ledger.sql): read live from StaffUsers."PaymentMethod", and an unset
-- method counts as Cash - so the per-line badge always agrees with the Cash/Digital totals.
--
-- Run AFTER supabase_payroll_hourly_days_worked_display.sql (this replaces that version). Safe to re-run.

drop function if exists public.admin_list_payroll_run_lines(text, text, uuid);

create or replace function public.admin_list_payroll_run_lines(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(
  line_id uuid,
  username text,
  display_name text,
  pay_type text,
  base_pay numeric,
  additions_total numeric,
  deductions_total numeric,
  net_pay numeric,
  notes text,
  days_worked numeric,
  daily_rate numeric,
  daily_rate_breakdown jsonb,
  payment_method text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."LineID", l."Username"::text, l."DisplayName"::text, coalesce(su."PayType", 'Salary')::text,
           l."BasePay", l."AdditionsTotal", l."DeductionsTotal", l."NetPay", l."Notes"::text,
           l."DaysWorked", l."DailyRate", l."DailyRateBreakdown",
           coalesce(su."PaymentMethod", 'Cash')::text
    from public."PayrollRunLines" l
    left join public."StaffUsers" su on su."Username" = l."Username"
    where l."RunID" = p_run_id
    order by l."DisplayName", l."Username";
end;
$$;

grant execute on function public.admin_list_payroll_run_lines(text, text, uuid) to anon;
