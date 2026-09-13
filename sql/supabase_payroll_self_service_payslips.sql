-- Self-service payslips: every StaffUsers login (not just Payroll Officers/Super Users) can view
-- and print their OWN finalized payslips - per "lets say each employee has login i want a portion
-- there that they can access their pay / payslips." Unlike every admin_* payroll RPC (gated by
-- is_payroll_authorized - Super User or Payroll Officer only), these two use is_staff_authorized
-- (supabase_staff_users_table.sql - any active login, same check admin_get_sales_by_confirmed_by
-- already relies on for the dashboard's Sales-by-Staff section) and hard-scope every row to
-- p_username itself - there is no way to pass in someone else's username and see their pay.
--
-- Only Finalized runs are ever returned - a Draft run's numbers can still change (line items,
-- base pay overrides) right up until Finalize, so showing it to the employee early would risk
-- them seeing a wrong figure. admin_finalize_payroll_run (supabase_payroll_tables.sql /
-- supabase_payroll_officer_access.sql) is unchanged - finalizing a run is what makes it visible
-- here, nothing new to trigger.
--
-- Run this AFTER supabase_payroll_hourly_days_worked_display.sql (reuses its pay_type/
-- days_worked/daily_rate columns).

-- ---------------------------------------------------------------------------
-- my_list_payslips: one row per Finalized run this employee has a line in, newest period first.

create or replace function public.my_list_payslips(p_username text, p_password text)
returns table(
  line_id uuid,
  run_id uuid,
  pay_cycle text,
  period_start date,
  period_end date,
  pay_date date,
  base_pay numeric,
  additions_total numeric,
  deductions_total numeric,
  net_pay numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."LineID", r."RunID", r."PayCycle"::text, r."PeriodStart", r."PeriodEnd", r."PayDate",
           l."BasePay", l."AdditionsTotal", l."DeductionsTotal", l."NetPay"
    from public."PayrollRunLines" l
    join public."PayrollRuns" r on r."RunID" = l."RunID"
    where l."Username" = p_username and r."Status" = 'Finalized'
    order by r."PeriodEnd" desc, r."PeriodStart" desc;
end;
$$;

-- ---------------------------------------------------------------------------
-- my_get_payslip: same shape as admin_get_payroll_payslip (supabase_payroll_hourly_days_worked_
-- display.sql), but ownership-checked (l."Username" = p_username) instead of admin-authorized -
-- an employee can only ever fetch their own line, and only once it's Finalized.

create or replace function public.my_get_payslip(p_username text, p_password text, p_line_id uuid)
returns table(
  line_id uuid,
  run_id uuid,
  username text,
  display_name text,
  pay_type text,
  pay_cycle text,
  period_start date,
  period_end date,
  pay_date date,
  status text,
  base_pay numeric,
  additions_total numeric,
  deductions_total numeric,
  net_pay numeric,
  notes text,
  days_worked numeric,
  daily_rate numeric,
  daily_rate_breakdown jsonb,
  items jsonb
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."LineID", r."RunID", l."Username"::text, l."DisplayName"::text, coalesce(su."PayType", 'Salary')::text, r."PayCycle"::text,
           r."PeriodStart", r."PeriodEnd", r."PayDate", r."Status"::text,
           l."BasePay", l."AdditionsTotal", l."DeductionsTotal", l."NetPay", l."Notes"::text,
           l."DaysWorked", l."DailyRate", l."DailyRateBreakdown",
           coalesce(
             (select jsonb_agg(jsonb_build_object('item_type', i."ItemType", 'label', i."Label", 'amount', i."Amount") order by i."ItemType", i."CreatedAtUtc")
              from public."PayrollRunLineItems" i where i."LineID" = l."LineID"),
             '[]'::jsonb
           )
    from public."PayrollRunLines" l
    join public."PayrollRuns" r on r."RunID" = l."RunID"
    left join public."StaffUsers" su on su."Username" = l."Username"
    where l."LineID" = p_line_id and l."Username" = p_username and r."Status" = 'Finalized';
end;
$$;

grant execute on function public.my_list_payslips(text, text) to anon;
grant execute on function public.my_get_payslip(text, text, uuid) to anon;
