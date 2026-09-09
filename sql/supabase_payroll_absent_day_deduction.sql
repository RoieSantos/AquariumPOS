-- Absent-day deduction for Salary employees. Previously, Undertime was only computed from days
-- that actually had a timesheet row - a day inside the pay period with NO entry at all (left
-- blank in the Timesheets weekly grid) contributed nothing, so a day the employee simply never
-- showed up for was treated the same as a day they weren't scheduled to work at all.
--
-- Per explicit confirmation, every calendar day inside the pay period now counts as an expected
-- workday: a blank day (no timesheet entry) is treated as fully absent and deducts a full standard
-- day, the same as if 0 hours had been logged. This applies to every day in the period, weekends
-- included - there's no separate rest-day concept in this system.
--
-- Hourly employees are unaffected: their Base Pay is already computed directly from whatever
-- hours were actually logged, so a blank day already contributes exactly 0 pay for that day (see
-- supabase_payroll_hourly_pay_type.sql) - no separate Undertime line exists for them.
--
-- Same external signature as before - create or replace only, no drop needed.
--
-- Run this AFTER supabase_payroll_hourly_pay_type.sql.

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
  v_line_id uuid;
  v_username text;
  v_monthly_salary numeric;
  v_pay_type text;
  v_daily_rate numeric;
  v_hourly_rate numeric;
  v_regular_hours numeric;
  v_overtime_hours numeric;
  v_undertime_hours numeric;
  v_base_pay numeric;
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

  for v_line_id, v_username, v_monthly_salary, v_pay_type, v_daily_rate in
    select l."LineID", l."Username", su."MonthlySalary", su."PayType", su."DailyRate"
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

      perform public.recompute_payroll_run_line(v_line_id);
    else
      v_hourly_rate := case when v_std_work_days_per_month > 0 and v_std_hours_per_day > 0
        then v_monthly_salary / (v_std_work_days_per_month * v_std_hours_per_day)
        else 0 end;

      -- Walk every calendar day in the period (not just days with a timesheet row) so a day with
      -- no entry at all - not even a partial one - is treated as fully absent, same as 0 hours.
      select coalesce(sum(greatest(coalesce(t."HoursWorked", 0) - v_std_hours_per_day, 0)), 0),
             coalesce(sum(greatest(v_std_hours_per_day - coalesce(t."HoursWorked", 0), 0)), 0)
        into v_overtime_hours, v_undertime_hours
        from generate_series(p_period_start, p_period_end, interval '1 day') as d(work_date)
        left join public."PayrollTimesheetEntries" t
          on t."Username" = v_username and t."WorkDate" = d.work_date::date;

      if v_overtime_hours > 0 and v_hourly_rate > 0 then
        insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
        values (
          v_line_id, 'Addition',
          'Overtime (' || trim(to_char(v_overtime_hours, 'FM999990.00')) || ' hrs)',
          round(v_overtime_hours * v_hourly_rate * v_ot_multiplier, 2)
        );
      end if;

      if v_undertime_hours > 0 and v_hourly_rate > 0 then
        insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
        values (
          v_line_id, 'Deduction',
          'Undertime/Absence (' || trim(to_char(v_undertime_hours, 'FM999990.00')) || ' hrs)',
          round(v_undertime_hours * v_hourly_rate, 2)
        );
      end if;

      if v_overtime_hours > 0 or v_undertime_hours > 0 then
        perform public.recompute_payroll_run_line(v_line_id);
      end if;
    end if;
  end loop;

  return v_run_id;
end;
$$;

grant execute on function public.admin_create_payroll_run(text, text, text, date, date, date) to anon;
