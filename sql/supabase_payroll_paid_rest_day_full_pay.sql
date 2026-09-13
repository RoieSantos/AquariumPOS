-- Fixes Paid Rest Day so it actually pays a day's worth of salary, instead of just being excluded
-- from the day-walk entirely. Per: "can we do if the employee has paid day off it will add a day
-- worth of salary to their pay."
--
-- Bug this fixes: supabase_payroll_base_pay_days_worked.sql rebuilt a Salary employee's Base Pay as
-- a sum over every day walked in the period (daily_rate per day, minus any undertime). It excluded
-- the employee's designated Paid Rest Day from that walk entirely (same "where v_paid_rest_day is
-- null or extract(dow from d.work_date) <> v_paid_rest_day" the older Undertime-deduction formula
-- used) - but under the OLD flat-salary formula, excluding a day from a separate deduction walk
-- meant "no deduction, so they keep their full flat pay for that day" (genuinely paid). Once Base
-- Pay stopped being flat and became purely additive per walked day, excluding the rest day from the
-- walk stopped paying for it too - it silently became functionally identical to an UNPAID rest day.
--
-- Fix: keep every day in the walk, including the Paid Rest Day, but force its overtime/undertime to
-- zero regardless of actual timesheet hours that day - so it always contributes one full day's
-- daily_rate to Base Pay with no deduction, and it stops being a source of Overtime credit too
-- (it's a paid day off, not a shift the employee is expected to log hours against).
--
-- Run this AFTER supabase_payroll_base_pay_days_worked.sql.

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
  v_expected_days numeric;
  v_days_worked numeric;
  v_base_pay numeric;
  v_monthly_salary numeric;
  v_overtime_amount numeric;
  v_period_flat_daily_rate numeric;
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

  v_period_days := (p_period_end - p_period_start) + 1;

  insert into public."PayrollRuns" ("PayCycle", "PeriodStart", "PeriodEnd", "PayDate", "CreatedBy")
  values (p_pay_cycle, p_period_start, p_period_end, p_pay_date, p_admin_username)
  returning "RunID" into v_run_id;

  -- Hourly employees start at 0 - their real Base Pay is computed from timesheets in the loop
  -- below. Salary employees keep the existing MonthlySalary/pay-cycle split as the starting
  -- entitlement the daily rate is derived from (below), before being reduced to actual days worked.
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

  for v_line_id, v_username, v_base_pay, v_pay_type, v_daily_rate, v_paid_rest_day, v_monthly_salary in
    select l."LineID", l."Username", l."BasePay", su."PayType", su."DailyRate", su."PaidRestDay", su."MonthlySalary"
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
      -- Semi-Monthly's rate is a single flat value for the whole period (unaffected by calendar
      -- month boundaries - it was never derived from month length). Weekly's rate is computed PER
      -- DAY below instead (Monthly Salary / that specific day's own month length), so a period
      -- crossing a month boundary blends two different daily rates rather than picking one.
      v_period_flat_daily_rate := case when v_period_days > 0 then v_base_pay / v_period_days else 0 end;

      -- Walk every calendar day in the period, pricing each at its own daily/hourly rate, grouped by
      -- calendar month - v_expected_days/v_overtime_amount/v_base_pay are the totals across all
      -- month groups summed (identical to summing every individual day), and v_daily_rate_breakdown
      -- is the same grouped data kept per-month for display (at most 2 groups for a 7-day Weekly
      -- period; always exactly 1 for Semi-Monthly, whose rate never varies within a period). The
      -- employee's designated Paid Rest Day (if any) has its overtime/undertime forced to zero
      -- regardless of actual timesheet hours that day, so it always contributes one full day's
      -- daily_rate with no deduction - it's a paid day off, not counted as an absence OR a shift
      -- that can earn Overtime.
      with raw_days as (
        select
          date_trunc('month', d.work_date) as month_key,
          case when v_paid_rest_day is not null and extract(dow from d.work_date) = v_paid_rest_day then 0
               else greatest(coalesce(t."HoursWorked", 0) - v_std_hours_per_day, 0) end as overtime_hours,
          case when v_paid_rest_day is not null and extract(dow from d.work_date) = v_paid_rest_day then 0
               else greatest(v_std_hours_per_day - coalesce(t."HoursWorked", 0), 0) end as undertime_hours,
          case when p_pay_cycle = 'Weekly'
            then v_monthly_salary / extract(day from (date_trunc('month', d.work_date) + interval '1 month' - interval '1 day'))
            else v_period_flat_daily_rate
          end as daily_rate
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

      -- Base Pay is already the summed per-day amount from the query above (same attendance-based
      -- model as Hourly, just blended across two rates when the period spans a month boundary) - no
      -- separate Undertime/Absence deduction line item any more; a day not worked (rest day or
      -- otherwise) just isn't counted as worked. DaysWorked/DailyRate are still stored so the UI can
      -- show a "day rate x days worked" breakdown - DailyRate here is the EFFECTIVE (weighted
      -- average) rate for display, since a blended period has no single true daily rate.
      v_undertime_days := case when v_std_hours_per_day > 0 then v_undertime_hours / v_std_hours_per_day else 0 end;
      v_days_worked := v_expected_days - v_undertime_days;
      v_base_pay := round(v_base_pay, 2);
      v_daily_rate := case when v_days_worked > 0 then round(v_base_pay / v_days_worked, 2) else round(v_period_flat_daily_rate, 2) end;

      update public."PayrollRunLines"
        set "BasePay" = v_base_pay, "DaysWorked" = v_days_worked, "DailyRate" = v_daily_rate,
            "DailyRateBreakdown" = v_daily_rate_breakdown
        where "LineID" = v_line_id;
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

grant execute on function public.admin_create_payroll_run(text, text, text, date, date, date) to anon;
