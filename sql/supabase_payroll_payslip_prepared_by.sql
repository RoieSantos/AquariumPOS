-- Shows who prepared a payroll run on its printed payslip, per "can you add the name of the
-- payroll officer that did prepare this payrun." PayrollRuns."CreatedBy" (supabase_payroll_
-- tables.sql) already stores the username of whoever ran admin_create_payroll_run - this just
-- surfaces their DisplayName (falling back to the raw username if that account was since deleted,
-- or to '-' if the run somehow has no CreatedBy) as a new `prepared_by` column on both payslip
-- RPCs, then prints it above the "Prepared By" signature line.
--
-- Run this AFTER supabase_payroll_self_service_payslips.sql (layers on top of
-- admin_get_payroll_payslip's/my_get_payslip's current signatures).

-- ---------------------------------------------------------------------------
-- admin_get_payroll_payslip: add prepared_by.

drop function if exists public.admin_get_payroll_payslip(text, text, uuid);

create or replace function public.admin_get_payroll_payslip(p_admin_username text, p_admin_password text, p_line_id uuid)
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
  items jsonb,
  prepared_by text
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
    select l."LineID", r."RunID", l."Username"::text, l."DisplayName"::text, coalesce(su."PayType", 'Salary')::text, r."PayCycle"::text,
           r."PeriodStart", r."PeriodEnd", r."PayDate", r."Status"::text,
           l."BasePay", l."AdditionsTotal", l."DeductionsTotal", l."NetPay", l."Notes"::text,
           l."DaysWorked", l."DailyRate", l."DailyRateBreakdown",
           coalesce(
             (select jsonb_agg(jsonb_build_object('item_type', i."ItemType", 'label', i."Label", 'amount', i."Amount") order by i."ItemType", i."CreatedAtUtc")
              from public."PayrollRunLineItems" i where i."LineID" = l."LineID"),
             '[]'::jsonb
           ),
           coalesce(preparer."DisplayName"::text, r."CreatedBy"::text, '-')
    from public."PayrollRunLines" l
    join public."PayrollRuns" r on r."RunID" = l."RunID"
    left join public."StaffUsers" su on su."Username" = l."Username"
    left join public."StaffUsers" preparer on preparer."Username" = r."CreatedBy"
    where l."LineID" = p_line_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- my_get_payslip: same prepared_by addition for the self-service payslip.

drop function if exists public.my_get_payslip(text, text, uuid);

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
  items jsonb,
  prepared_by text
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
           ),
           coalesce(preparer."DisplayName"::text, r."CreatedBy"::text, '-')
    from public."PayrollRunLines" l
    join public."PayrollRuns" r on r."RunID" = l."RunID"
    left join public."StaffUsers" su on su."Username" = l."Username"
    left join public."StaffUsers" preparer on preparer."Username" = r."CreatedBy"
    where l."LineID" = p_line_id and l."Username" = p_username and r."Status" = 'Finalized';
end;
$$;

grant execute on function public.admin_get_payroll_payslip(text, text, uuid) to anon;
grant execute on function public.my_get_payslip(text, text, uuid) to anon;
