-- Semi-Monthly Salary employees get a FIXED per-cutoff Base Pay - no per-day attendance math -
-- per "for semi-monthly employees no need to compute per day rate.. its fixed E.G. monthly 21000
-- then their per cutoff pay is half of that 21000/2 = 10500." Previously every Salary employee
-- (regardless of cycle) went through the same day-by-day walk (supabase_payroll_hourly_days_
-- worked_display.sql), which reduced Base Pay for any undertime/absence - that reduction now only
-- applies to Weekly Salary employees (still needed there since a week can cross a calendar month
-- boundary, requiring two different derived daily rates - see the comment in that branch below).
-- A Semi-Monthly Salary employee's Base Pay is always exactly MonthlySalary / 2, full stop.
--
-- DaysWorked/DailyRate are left null for these lines (not "days worked x day rate = base pay" -
-- that formula no longer holds, so showing it would misrepresent a fixed salary as attendance-
-- based) - the UI's existing hasDaysWorked/hasDaysWorked-style null checks already render "-" for
-- both columns in that case (see payrollRun.js/payrollPrint.js), same as they did for Hourly
-- before supabase_payroll_base_pay_days_worked.sql. A DailyRate value IS still computed and stored
-- (MonthlySalary / StandardWorkDaysPerMonth) purely so Paid Rest Day - a flat "one day's pay"
-- addition below - has a "one day" figure to use; it's just not surfaced as a days-worked breakdown.
--
-- Same signature as admin_create_payroll_run - create or replace is enough, no drop needed.
--
-- Run this AFTER supabase_payroll_hourly_days_worked_display.sql.

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
  v_has_paid_rest_day boolean;
  v_hourly_rate numeric;
  v_regular_hours numeric;
  v_overtime_hours numeric;
  v_undertime_hours numeric;
  v_undertime_days numeric;
  v_expected_days numeric;
  v_days_worked numeric;
  v_base_pay numeric;
  v_monthly_salary numeric;
  v_overtime_amount numeric;
  v_daily_rate_breakdown jsonb;
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

  if not exists (select 1 from public."StaffUsers" where "IsActive" is true and "PayCycle" = p_pay_cycle) then
    raise exception 'No active employees are enrolled in the % pay cycle.', p_pay_cycle;
  end if;

  v_period_days := (p_period_end - p_period_start) + 1;

  insert into public."PayrollRuns" ("PayCycle", "PeriodStart", "PeriodEnd", "PayDate", "CreatedBy")
  values (p_pay_cycle, p_period_start, p_period_end, p_pay_date, p_admin_username)
  returning "RunID" into v_run_id;

  -- Hourly employees start at 0 - their real Base Pay is computed from timesheets in the loop
  -- below. Salary employees keep the existing MonthlySalary/pay-cycle split as the starting
  -- entitlement (Weekly's is later adjusted for attendance in the loop below; SemiMonthly's is
  -- now final as-is - see the Salary branch below). Skips anyone with zero timesheet entries in
  -- the period entirely.
  insert into public."PayrollRunLines" ("RunID", "Username", "DisplayName", "BasePay", "NetPay")
  select
    v_run_id,
    su."Username",
    su."DisplayName",
    case
      when su."PayType" = 'Hourly' then 0
      when p_pay_cycle = 'SemiMonthly' then round(su."MonthlySalary" / 2, 2)
      else round(su."MonthlySalary" * 12 / 52, 2)
    end,
    case
      when su."PayType" = 'Hourly' then 0
      when p_pay_cycle = 'SemiMonthly' then round(su."MonthlySalary" / 2, 2)
      else round(su."MonthlySalary" * 12 / 52, 2)
    end
  from public."StaffUsers" su
  where su."IsActive" is true and su."PayCycle" = p_pay_cycle
    and exists (
      select 1 from public."PayrollTimesheetEntries" t
      where t."Username" = su."Username" and t."WorkDate" between p_period_start and p_period_end
    );

  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    delete from public."PayrollRuns" where "RunID" = v_run_id;
    raise exception 'No employees in the % pay cycle have any timesheet entries between % and %.', p_pay_cycle, p_period_start, p_period_end;
  end if;

  select coalesce("StandardHoursPerDay", 8), coalesce("StandardWorkDaysPerMonth", 26), coalesce("OvertimeMultiplier", 1.25)
    into v_std_hours_per_day, v_std_work_days_per_month, v_ot_multiplier
    from public."PayrollCutoffSettings"
    where "Id" = 1;

  v_std_hours_per_day := coalesce(v_std_hours_per_day, 8);
  v_std_work_days_per_month := coalesce(v_std_work_days_per_month, 26);
  v_ot_multiplier := coalesce(v_ot_multiplier, 1.25);

  for v_line_id, v_username, v_base_pay, v_pay_type, v_daily_rate, v_has_paid_rest_day, v_monthly_salary in
    select l."LineID", l."Username", l."BasePay", su."PayType", su."DailyRate", su."HasPaidRestDay", su."MonthlySalary"
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
      update public."PayrollRunLines"
        set "BasePay" = v_base_pay, "DaysWorked" = v_regular_hours, "DailyRate" = round(v_hourly_rate, 2)
        where "LineID" = v_line_id;

      if v_overtime_hours > 0 and v_hourly_rate > 0 then
        insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
        values (
          v_line_id, 'Addition',
          'Overtime (' || trim(to_char(v_overtime_hours, 'FM999990.00')) || ' hrs)',
          round(v_overtime_hours * v_hourly_rate * v_ot_multiplier, 2)
        );
      end if;
    elsif p_pay_cycle = 'SemiMonthly' then
      -- Fixed per-cutoff pay, no attendance math for Base Pay itself - v_base_pay already holds
      -- round(MonthlySalary / 2, 2) from the seeding insert above, so there's nothing to recompute
      -- there. DailyRate is still derived (MonthlySalary / StandardWorkDaysPerMonth) purely as the
      -- "one day" figure Paid Rest Day needs below - DaysWorked stays null so the UI doesn't show a
      -- misleading "x days worked" breakdown for what is really a flat amount.
      --
      -- Overtime still applies though, same rule and rate basis as every other pay type: any hours
      -- logged past StandardHoursPerDay (8) on a given day are paid at hourly-equivalent x
      -- OvertimeMultiplier, on top of the fixed Base Pay - per "overtime per hour rate calculation
      -- will be the same for semi monthly as well / all the hours exceed for 8 hours a day will be
      -- subject for overtime pay." The hourly-equivalent rate is derived from the same DailyRate
      -- above (DailyRate / StandardHoursPerDay), since Semi-Monthly has no per-day timesheet-driven
      -- rate to fall back on the way Weekly does.
      v_daily_rate := case when v_std_work_days_per_month > 0 then round(v_monthly_salary / v_std_work_days_per_month, 2) else 0 end;
      v_hourly_rate := case when v_std_hours_per_day > 0 then v_daily_rate / v_std_hours_per_day else 0 end;

      select coalesce(sum(greatest(t."HoursWorked" - v_std_hours_per_day, 0)), 0)
        into v_overtime_hours
        from public."PayrollTimesheetEntries" t
        where t."Username" = v_username
          and t."WorkDate" between p_period_start and p_period_end;

      if v_overtime_hours > 0 and v_hourly_rate > 0 then
        insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
        values (
          v_line_id, 'Addition',
          'Overtime (' || trim(to_char(v_overtime_hours, 'FM999990.00')) || ' hrs)',
          round(v_overtime_hours * v_hourly_rate * v_ot_multiplier, 2)
        );
      end if;

      update public."PayrollRunLines"
        set "DaysWorked" = null, "DailyRate" = v_daily_rate, "DailyRateBreakdown" = null
        where "LineID" = v_line_id;
    else
      -- Weekly Salary only reaches here - a week can cross a calendar month boundary, so unlike
      -- Semi-Monthly's single flat cutoff amount, this still needs to walk every calendar day and
      -- price it against that day's own month length (Monthly Salary / days in that month),
      -- blending two different daily rates when the period spans two months. No day is special-
      -- cased here (Paid Rest Day is handled below as a flat addition instead).
      with raw_days as (
        select
          date_trunc('month', d.work_date) as month_key,
          greatest(coalesce(t."HoursWorked", 0) - v_std_hours_per_day, 0) as overtime_hours,
          greatest(v_std_hours_per_day - coalesce(t."HoursWorked", 0), 0) as undertime_hours,
          v_monthly_salary / extract(day from (date_trunc('month', d.work_date) + interval '1 month' - interval '1 day')) as daily_rate
        from generate_series(p_period_start, p_period_end, interval '1 day') as d(work_date)
        left join public."PayrollTimesheetEntries" t
          on t."Username" = v_username and t."WorkDate" = d.work_date::date
      ),
      month_grouped as (
        select
          month_key,
          max(daily_rate) as daily_rate,
          count(*) as days_in_period,
          sum(overtime_hours) as overtime_hours,
          sum(undertime_hours) as undertime_hours,
          sum(case when v_std_hours_per_day > 0 then (v_std_hours_per_day - undertime_hours) / v_std_hours_per_day else 0 end) as days_worked,
          sum(overtime_hours * (case when v_std_hours_per_day > 0 then daily_rate / v_std_hours_per_day else 0 end) * v_ot_multiplier) as overtime_amount,
          sum(daily_rate - undertime_hours * (case when v_std_hours_per_day > 0 then daily_rate / v_std_hours_per_day else 0 end)) as subtotal
        from raw_days
        group by month_key
      )
      select
        coalesce(sum(overtime_hours), 0),
        coalesce(sum(undertime_hours), 0),
        coalesce(sum(days_in_period), 0),
        coalesce(sum(overtime_amount), 0),
        coalesce(sum(subtotal), 0),
        coalesce(jsonb_agg(jsonb_build_object(
          'month', to_char(month_key, 'Mon YYYY'),
          'days_worked', round(days_worked, 2),
          'daily_rate', round(daily_rate, 2),
          'subtotal', round(subtotal, 2)
        ) order by month_key), '[]'::jsonb)
        into v_overtime_hours, v_undertime_hours, v_expected_days, v_overtime_amount, v_base_pay, v_daily_rate_breakdown
        from month_grouped;

      if v_overtime_hours > 0 and v_overtime_amount > 0 then
        insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
        values (
          v_line_id, 'Addition',
          'Overtime (' || trim(to_char(v_overtime_hours, 'FM999990.00')) || ' hrs)',
          round(v_overtime_amount, 2)
        );
      end if;

      -- Base Pay is already the summed per-day amount from the query above (a day not worked just
      -- isn't counted as worked) - DaysWorked/DailyRate are still stored so the UI can show a "day
      -- rate x days worked" breakdown - DailyRate here is the EFFECTIVE (weighted average) rate for
      -- display, since a blended period has no single true daily rate.
      v_undertime_days := case when v_std_hours_per_day > 0 then v_undertime_hours / v_std_hours_per_day else 0 end;
      v_days_worked := v_expected_days - v_undertime_days;
      v_base_pay := round(v_base_pay, 2);
      v_daily_rate := case when v_days_worked > 0 then round(v_base_pay / v_days_worked, 2) else 0 end;

      update public."PayrollRunLines"
        set "BasePay" = v_base_pay, "DaysWorked" = v_days_worked, "DailyRate" = v_daily_rate,
            "DailyRateBreakdown" = v_daily_rate_breakdown
        where "LineID" = v_line_id;
    end if;

    -- Paid Rest Day: a flat extra day's pay, on top of whatever Base Pay resolved to - v_daily_rate
    -- at this point holds the right "one day" figure for every branch above (Hourly's own
    -- DailyRate, Semi-Monthly Salary's MonthlySalary/StandardWorkDaysPerMonth, or Weekly Salary's
    -- just-computed effective daily rate).
    if coalesce(v_has_paid_rest_day, false) and coalesce(v_daily_rate, 0) > 0 then
      insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
      values (v_line_id, 'Addition', 'Paid Rest Day', v_daily_rate);
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

    -- Unconditional: Hourly always needs this (BasePay just changed above) and Salary/Paid Rest
    -- Day/advance line items may or may not have been added this iteration - recompute is cheap and
    -- safe to run regardless.
    perform public.recompute_payroll_run_line(v_line_id);
  end loop;

  return v_run_id;
end;
$$;

grant execute on function public.admin_create_payroll_run(text, text, text, date, date, date) to anon;
