-- Cash Advance tracking: employees get a Cash Advance released on a recurring basis (e.g. every
-- Thursday), separate from and ahead of any actual payroll run for that period. Each advance is
-- logged the moment it's released; the next payroll run created for that employee automatically
-- pulls in every still-Outstanding advance as a Deduction line item and marks it Applied - same
-- auto-pull pattern as Overtime/Absence from Timesheets (supabase_payroll_timesheets.sql) and
-- Undertime/Absence (supabase_payroll_absent_day_deduction.sql). Confirmed: auto-apply, not a
-- manual pick-list, though the resulting Deduction line item can still be removed/edited on the
-- Payroll Run page before the run is finalized, same as any other line item.
--
-- Run this AFTER supabase_payroll_employee_no.sql.

create table if not exists public."PayrollCashAdvances" (
    "AdvanceID" uuid primary key default gen_random_uuid(),
    "Username" varchar(100) not null references public."StaffUsers"("Username"),
    "AdvanceDate" date not null,
    "Amount" numeric(18, 2) not null check ("Amount" > 0),
    "Notes" varchar(500),
    "Status" varchar(20) not null default 'Outstanding' check ("Status" in ('Outstanding', 'Applied', 'Cancelled')),
    "AppliedToRunID" uuid references public."PayrollRuns"("RunID"),
    "AppliedToLineID" uuid references public."PayrollRunLines"("LineID"),
    "AppliedAtUtc" timestamptz,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."PayrollCashAdvances" enable row level security;
revoke all on public."PayrollCashAdvances" from anon, authenticated;

create index if not exists "IX_PayrollCashAdvances_Username_Status" on public."PayrollCashAdvances" ("Username", "Status");

comment on table public."PayrollCashAdvances" is 'Cash advances released to employees (e.g. weekly), auto-deducted from their next payroll run.';

-- ---------------------------------------------------------------------------
-- admin_add_cash_advance: log an advance the moment it's released.

create or replace function public.admin_add_cash_advance(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_advance_date date,
  p_amount numeric,
  p_notes text default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_username is null or trim(p_username) = '' then
    return query select false, 'Employee is required.'::text;
    return;
  end if;

  if not exists (select 1 from public."StaffUsers" where "Username" = p_username) then
    return query select false, 'That employee no longer exists.'::text;
    return;
  end if;

  if p_advance_date is null then
    return query select false, 'Advance date is required.'::text;
    return;
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return query select false, 'Amount must be greater than zero.'::text;
    return;
  end if;

  insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Notes", "CreatedBy")
  values (p_username, p_advance_date, p_amount, nullif(trim(p_notes), ''), p_admin_username);

  return query select true, 'Cash advance logged.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_cash_advances: journal-style list, filterable by employee/status/date range.

drop function if exists public.admin_list_cash_advances(text, text, text, text, date, date, int, int);

create or replace function public.admin_list_cash_advances(
  p_admin_username text,
  p_admin_password text,
  p_username text default null,
  p_status text default null,
  p_date_start date default null,
  p_date_end date default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  advance_id uuid,
  username text,
  display_name text,
  advance_date date,
  amount numeric,
  notes text,
  status text,
  applied_to_run_id uuid,
  applied_at_utc timestamptz,
  created_by text,
  created_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select a."AdvanceID", a."Username"::text, su."DisplayName"::text, a."AdvanceDate", a."Amount", a."Notes"::text,
           a."Status"::text, a."AppliedToRunID", a."AppliedAtUtc", a."CreatedBy"::text, a."CreatedAtUtc",
           count(*) over()
    from public."PayrollCashAdvances" a
    join public."StaffUsers" su on su."Username" = a."Username"
    where (p_username is null or a."Username" = p_username)
      and (p_status is null or a."Status" = p_status)
      and (p_date_start is null or a."AdvanceDate" >= p_date_start)
      and (p_date_end is null or a."AdvanceDate" <= p_date_end)
    order by a."AdvanceDate" desc, a."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_delete_cash_advance: only while still Outstanding - one already Applied to a run is part
-- of that run's history and should be removed via the run's line item instead (which would leave
-- it orphaned as Applied with no corresponding line item, so it's blocked here entirely).

create or replace function public.admin_delete_cash_advance(p_admin_username text, p_admin_password text, p_advance_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select "Status" into v_status from public."PayrollCashAdvances" where "AdvanceID" = p_advance_id;

  if v_status is null then
    return query select false, 'Cash advance not found.'::text;
    return;
  end if;

  if v_status <> 'Outstanding' then
    return query select false, 'Only an Outstanding cash advance can be deleted - this one is already ' || v_status || '.'::text;
    return;
  end if;

  delete from public."PayrollCashAdvances" where "AdvanceID" = p_advance_id;

  return query select true, 'Cash advance deleted.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_employees: add outstanding_cash_advance so Payroll Setup's Employees table
-- shows who currently has a pending balance.

drop function if exists public.admin_list_payroll_employees(text, text);

create or replace function public.admin_list_payroll_employees(p_admin_username text, p_admin_password text)
returns table(
  username text,
  display_name text,
  is_active boolean,
  pay_cycle text,
  monthly_salary numeric,
  payment_method text,
  pay_type text,
  daily_rate numeric,
  paid_rest_day int,
  employee_no text,
  outstanding_cash_advance numeric
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
    select su."Username"::text, su."DisplayName"::text, su."IsActive", su."PayCycle"::text, su."MonthlySalary", su."PaymentMethod"::text, su."PayType"::text, su."DailyRate", su."PaidRestDay", su."EmployeeNo"::text,
           coalesce((select sum(a."Amount") from public."PayrollCashAdvances" a where a."Username" = su."Username" and a."Status" = 'Outstanding'), 0)
    from public."StaffUsers" su
    order by su."DisplayName", su."Username";
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_payroll_run: same signature - now also pulls in every Outstanding Cash Advance for
-- each employee on the run as a Deduction line item, marking it Applied.

create or replace function public.admin_create_payroll_run(
  p_admin_username text,
  p_admin_password text,
  p_pay_cycle text,
  p_period_start date,
  p_period_end date,
  p_pay_date date
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_run_id uuid;
  v_inserted int;
  v_std_hours_per_day numeric;
  v_std_work_days_per_month numeric;
  v_ot_multiplier numeric;
  v_period_days numeric;
  v_line_id uuid;
  v_username text;
  v_pay_type text;
  v_daily_rate numeric;
  v_paid_rest_day int;
  v_hourly_rate numeric;
  v_regular_hours numeric;
  v_overtime_hours numeric;
  v_undertime_hours numeric;
  v_undertime_days numeric;
  v_base_pay numeric;
  v_advance_id uuid;
  v_advance_date date;
  v_advance_amount numeric;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_pay_cycle is null or p_pay_cycle not in ('SemiMonthly', 'Weekly') then
    raise exception 'Pay cycle must be Semi-Monthly or Weekly.';
  end if;

  if p_period_start is null or p_period_end is null or p_period_end < p_period_start then
    raise exception 'A valid period start/end is required.';
  end if;

  v_period_days := (p_period_end - p_period_start) + 1;

  insert into public."PayrollRuns" ("PayCycle", "PeriodStart", "PeriodEnd", "PayDate", "CreatedBy")
  values (p_pay_cycle, p_period_start, p_period_end, p_pay_date, p_admin_username)
  returning "RunID" into v_run_id;

  -- Hourly employees start at 0 - their real Base Pay is computed from timesheets in the loop
  -- below. Salary employees keep the existing MonthlySalary/pay-cycle split.
  insert into public."PayrollRunLines" ("RunID", "Username", "DisplayName", "BasePay", "NetPay")
  select
    v_run_id,
    "Username",
    "DisplayName",
    case
      when "PayType" = 'Hourly' then 0
      when p_pay_cycle = 'SemiMonthly' then round("MonthlySalary" / 2, 2)
      else round("MonthlySalary" * 12 / 52, 2)
    end,
    case
      when "PayType" = 'Hourly' then 0
      when p_pay_cycle = 'SemiMonthly' then round("MonthlySalary" / 2, 2)
      else round("MonthlySalary" * 12 / 52, 2)
    end
  from public."StaffUsers"
  where "IsActive" is true and "PayCycle" = p_pay_cycle;

  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    delete from public."PayrollRuns" where "RunID" = v_run_id;
    raise exception 'No active employees are enrolled in the % pay cycle.', p_pay_cycle;
  end if;

  select coalesce("StandardHoursPerDay", 8), coalesce("StandardWorkDaysPerMonth", 26), coalesce("OvertimeMultiplier", 1.25)
    into v_std_hours_per_day, v_std_work_days_per_month, v_ot_multiplier
    from public."PayrollCutoffSettings"
    where "Id" = 1;

  v_std_hours_per_day := coalesce(v_std_hours_per_day, 8);
  v_std_work_days_per_month := coalesce(v_std_work_days_per_month, 26);
  v_ot_multiplier := coalesce(v_ot_multiplier, 1.25);

  for v_line_id, v_username, v_base_pay, v_pay_type, v_daily_rate, v_paid_rest_day in
    select l."LineID", l."Username", l."BasePay", su."PayType", su."DailyRate", su."PaidRestDay"
    from public."PayrollRunLines" l
    join public."StaffUsers" su on su."Username" = l."Username"
    where l."RunID" = v_run_id
  loop
    if v_pay_type = 'Hourly' then
      v_hourly_rate := case when v_std_hours_per_day > 0 then coalesce(v_daily_rate, 0) / v_std_hours_per_day else 0 end;

      select coalesce(sum(least(t."HoursWorked", v_std_hours_per_day)), 0),
             coalesce(sum(greatest(t."HoursWorked" - v_std_hours_per_day, 0)), 0)
        into v_regular_hours, v_overtime_hours
        from public."PayrollTimesheetEntries" t
        where t."Username" = v_username
          and t."WorkDate" between p_period_start and p_period_end;

      v_base_pay := round(v_regular_hours * v_hourly_rate, 2);
      update public."PayrollRunLines" set "BasePay" = v_base_pay where "LineID" = v_line_id;

      if v_overtime_hours > 0 and v_hourly_rate > 0 then
        insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
        values (
          v_line_id, 'Addition',
          'Overtime (' || trim(to_char(v_overtime_hours, 'FM999990.00')) || ' hrs)',
          round(v_overtime_hours * v_hourly_rate * v_ot_multiplier, 2)
        );
      end if;
    else
      -- Rate derived from THIS period's own Base Pay and length (supabase_payroll_absence_rate_fix.sql).
      v_hourly_rate := case when v_period_days > 0 and v_std_hours_per_day > 0
        then v_base_pay / (v_period_days * v_std_hours_per_day)
        else 0 end;

      -- Walk every calendar day in the period except the employee's designated Paid Rest Day (if
      -- any) - that weekday never generates an Absence deduction, even if left blank.
      select coalesce(sum(greatest(coalesce(t."HoursWorked", 0) - v_std_hours_per_day, 0)), 0),
             coalesce(sum(greatest(v_std_hours_per_day - coalesce(t."HoursWorked", 0), 0)), 0)
        into v_overtime_hours, v_undertime_hours
        from generate_series(p_period_start, p_period_end, interval '1 day') as d(work_date)
        left join public."PayrollTimesheetEntries" t
          on t."Username" = v_username and t."WorkDate" = d.work_date::date
        where v_paid_rest_day is null or extract(dow from d.work_date) <> v_paid_rest_day;

      if v_overtime_hours > 0 and v_hourly_rate > 0 then
        insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
        values (
          v_line_id, 'Addition',
          'Overtime (' || trim(to_char(v_overtime_hours, 'FM999990.00')) || ' hrs)',
          round(v_overtime_hours * v_hourly_rate * v_ot_multiplier, 2)
        );
      end if;

      if v_undertime_hours > 0 and v_hourly_rate > 0 then
        -- Shown as days (not hours) worked short - a Salary employee's absence/rest day is
        -- naturally counted in whole days, not hours.
        v_undertime_days := case when v_std_hours_per_day > 0 then v_undertime_hours / v_std_hours_per_day else 0 end;
        insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
        values (
          v_line_id, 'Deduction',
          'Undertime/Absence (' || trim(to_char(v_undertime_days, 'FM999990.00')) || ' day(s))',
          round(v_undertime_hours * v_hourly_rate, 2)
        );
      end if;
    end if;

    -- Pull in every still-Outstanding Cash Advance for this employee, one line item each so the
    -- officer can see exactly what was advanced and when; each advance is marked Applied so it's
    -- never pulled into a second run.
    for v_advance_id, v_advance_date, v_advance_amount in
      select "AdvanceID", "AdvanceDate", "Amount"
      from public."PayrollCashAdvances"
      where "Username" = v_username and "Status" = 'Outstanding'
      order by "AdvanceDate"
    loop
      insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
      values (v_line_id, 'Deduction', 'Cash Advance (' || to_char(v_advance_date, 'Mon DD') || ')', v_advance_amount);

      update public."PayrollCashAdvances"
        set "Status" = 'Applied', "AppliedToRunID" = v_run_id, "AppliedToLineID" = v_line_id, "AppliedAtUtc" = timezone('utc', now())
        where "AdvanceID" = v_advance_id;
    end loop;

    -- Unconditional: Hourly always needs this (BasePay just changed above) and Salary/advance
    -- line items may or may not have been added this iteration - recompute is cheap and safe to
    -- run regardless.
    perform public.recompute_payroll_run_line(v_line_id);
  end loop;

  return v_run_id;
end;
$$;

grant execute on function public.admin_add_cash_advance(text, text, text, date, numeric, text) to anon;
grant execute on function public.admin_list_cash_advances(text, text, text, text, date, date, int, int) to anon;
grant execute on function public.admin_delete_cash_advance(text, text, uuid) to anon;
grant execute on function public.admin_list_payroll_employees(text, text) to anon;
grant execute on function public.admin_create_payroll_run(text, text, text, date, date, date) to anon;