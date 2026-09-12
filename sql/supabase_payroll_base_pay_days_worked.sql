-- Salary employees' Base Pay was a flat prorated-salary figure (MonthlySalary/2 or *12/52) with a
-- separate "Undertime/Absence" Deduction line item bolted on for any day short of full hours -
-- including a scheduled weekly (unpaid) rest day, which then showed up looking like a
-- disciplinary absence rather than a normal day off (see supabase_payroll_paid_rest_day.sql for
-- the already-existing PAID rest day case, which is different - that one is fully excused with no
-- deduction at all).
--
-- Base Pay is now computed the same attendance-based way Hourly employees already are: a per-day
-- rate x the number of days actually worked this period (period days, minus any Paid Rest Day
-- occurrences, minus any day short of full hours). No more separate Undertime/Absence deduction
-- line for Salary employees - a day not worked just isn't counted as a day worked, arithmetically
-- identical to before (dailyRate x daysWorked == old flat BasePay - old Undertime/Absence amount)
-- but no longer labeled as an absence.
--
-- DaysWorked/DailyRate are stored on PayrollRunLines so the Payroll Run line modal and the printed
-- payslip can both show the "day rate x days worked" breakdown instead of just the resulting
-- total. Both are left null for Hourly employees (already attendance-based via actual hours, nothing new to show).
--
-- Per officer instruction, a Weekly employee's daily rate is Monthly Salary / days in that day's
-- own calendar month (e.g. Php 15,000 / 30 = Php 500.00/day in a 30-day month), NOT derived from
-- the 7-day period length or the existing MonthlySalary*12/52 annualization (that annualized
-- figure is still used only as the flat starting entitlement inserted per employee before the loop
-- below runs and replaces it). A 7-day period that crosses a calendar month boundary is BLENDED -
-- each day in the period is priced using its own month's day-count, then summed - rather than
-- picking one month's rate for the whole week; a day in August and a day in September within the
-- same pay period are genuinely paid at two different daily rates. DailyRate as stored/displayed
-- for such a blended period is an effective rate (BasePay / DaysWorked), not any single day's rate;
-- DailyRateBreakdown (jsonb) additionally lists each month segment's own days-worked/rate/subtotal
-- so the Payroll Run line modal and payslip can show the two rates broken out, not just the blend.
-- A Semi-Monthly employee's daily rate is unchanged: the flat half-month entitlement spread across
-- that period's own day count (15 or 16 days depending on the cutoff) - constant regardless of
-- month boundaries, since it was never derived from calendar-month length to begin with.
--
-- Run this AFTER supabase_payroll_cash_advances.sql.

alter table public."PayrollRunLines"
    add column if not exists "DaysWorked" numeric(9, 2),
    add column if not exists "DailyRate" numeric(18, 2),
    add column if not exists "DailyRateBreakdown" jsonb;

-- ---------------------------------------------------------------------------
-- admin_create_payroll_run: same signature - Salary branch now writes BasePay/DaysWorked/DailyRate
-- back to the line instead of leaving BasePay flat and posting a separate absence deduction.

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

      -- Walk every calendar day in the period except the employee's designated Paid Rest Day (if
      -- any), pricing each remaining day at its own daily/hourly rate, grouped by calendar month -
      -- v_expected_days/v_overtime_amount/v_base_pay are the totals across all month groups summed
      -- (identical to summing every individual day), and v_daily_rate_breakdown is the same grouped
      -- data kept per-month for display (at most 2 groups for a 7-day Weekly period; always exactly
      -- 1 for Semi-Monthly, whose rate never varies within a period).
      with raw_days as (
        select
          date_trunc('month', d.work_date) as month_key,
          greatest(coalesce(t."HoursWorked", 0) - v_std_hours_per_day, 0) as overtime_hours,
          greatest(v_std_hours_per_day - coalesce(t."HoursWorked", 0), 0) as undertime_hours,
          case when p_pay_cycle = 'Weekly'
            then v_monthly_salary / extract(day from (date_trunc('month', d.work_date) + interval '1 month' - interval '1 day'))
            else v_period_flat_daily_rate
          end as daily_rate
        from generate_series(p_period_start, p_period_end, interval '1 day') as d(work_date)
        left join public."PayrollTimesheetEntries" t
          on t."Username" = v_username and t."WorkDate" = d.work_date::date
        where v_paid_rest_day is null or extract(dow from d.work_date) <> v_paid_rest_day
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

-- ---------------------------------------------------------------------------
-- admin_list_payroll_run_lines: add days_worked/daily_rate/daily_rate_breakdown so the Payroll Run
-- line modal can show the "day rate x days worked" breakdown for Salary employees, including the
-- two-rates-in-one-period case for a Weekly period that spans a calendar month boundary.

drop function if exists public.admin_list_payroll_run_lines(text, text, uuid);

create or replace function public.admin_list_payroll_run_lines(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(
  line_id uuid,
  username text,
  display_name text,
  base_pay numeric,
  additions_total numeric,
  deductions_total numeric,
  net_pay numeric,
  notes text,
  days_worked numeric,
  daily_rate numeric,
  daily_rate_breakdown jsonb
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
    select "LineID", "Username"::text, "DisplayName"::text, "BasePay", "AdditionsTotal", "DeductionsTotal", "NetPay", "Notes"::text,
           "DaysWorked", "DailyRate", "DailyRateBreakdown"
    from public."PayrollRunLines"
    where "RunID" = p_run_id
    order by "DisplayName", "Username";
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_get_payroll_payslip: same days_worked/daily_rate addition for the printed payslip.

drop function if exists public.admin_get_payroll_payslip(text, text, uuid);

create or replace function public.admin_get_payroll_payslip(p_admin_username text, p_admin_password text, p_line_id uuid)
returns table(
  line_id uuid,
  run_id uuid,
  username text,
  display_name text,
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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."LineID", r."RunID", l."Username"::text, l."DisplayName"::text, r."PayCycle"::text,
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
    where l."LineID" = p_line_id;
end;
$$;

grant execute on function public.admin_create_payroll_run(text, text, text, date, date, date) to anon;
grant execute on function public.admin_list_payroll_run_lines(text, text, uuid) to anon;
grant execute on function public.admin_get_payroll_payslip(text, text, uuid) to anon;
