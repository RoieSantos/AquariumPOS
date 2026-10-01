-- Read-only check for "absent is blank in the timesheet but it's not deducting for the semi-monthly
-- employee" - changes nothing. Looks at the most recently created Semi-Monthly payroll run and
-- shows, per employee on it, why an Undertime/Absence deduction was or wasn't posted under the rule
-- in supabase_payroll_semimonthly_absent_deduction.sql.
--
-- How to read it:
--   new_rule_installed = false  -> supabase_payroll_semimonthly_absent_deduction.sql has not been
--                                  run yet; run it first.
--   run_created_at              -> a run created BEFORE that script was applied keeps its old
--                                  numbers; delete the Draft run and create it again.
--   days_short = 0              -> the employee still reached the expected days for the cutoff
--                                  (Standard Work Days / Month / 2), so the blank days are treated
--                                  as rest days and nothing is deducted.
--   deduction_under_new_rule    -> what a run created now would deduct;
--   deduction_on_this_run       -> what this run actually has.

with settings as (
  select
    coalesce((select "StandardHoursPerDay" from public."PayrollCutoffSettings" where "Id" = 1), 8) as std_hours,
    coalesce((select "StandardWorkDaysPerMonth" from public."PayrollCutoffSettings" where "Id" = 1), 26) as std_days
),
run as (
  select *
  from public."PayrollRuns"
  where "PayCycle" = 'SemiMonthly'
  order by "CreatedAtUtc" desc
  limit 1
)
select
  position('v_days_short' in pg_get_functiondef('public.admin_create_payroll_run(text,text,text,date,date,date)'::regprocedure)) > 0 as new_rule_installed,
  r."PeriodStart" as period_start,
  r."PeriodEnd" as period_end,
  r."Status" as run_status,
  r."CreatedAtUtc" as run_created_at,
  l."DisplayName" as employee,
  su."PayType" as pay_type,
  ts.days_with_hours,
  (r."PeriodEnd" - r."PeriodStart") + 1 - ts.days_with_hours as blank_days,
  round(ts.days_worked, 2) as days_worked,
  s.std_days / 2 as expected_days,
  greatest(s.std_days / 2 - ts.days_worked, 0) as days_short,
  case when su."PayType" = 'Hourly' then null
       else least(round(greatest(s.std_days / 2 - ts.days_worked, 0) * su."MonthlySalary" / s.std_days, 2), l."BasePay")
  end as deduction_under_new_rule,
  (select coalesce(sum(i."Amount"), 0)
     from public."PayrollRunLineItems" i
    where i."LineID" = l."LineID" and i."ItemType" = 'Deduction' and i."Label" ilike 'Undertime%') as deduction_on_this_run
from run r
cross join settings s
join public."PayrollRunLines" l on l."RunID" = r."RunID"
join public."StaffUsers" su on su."Username" = l."Username"
cross join lateral (
  select count(*) as days_with_hours,
         coalesce(sum(least(t."HoursWorked", s.std_hours) / nullif(s.std_hours, 0)), 0) as days_worked
  from public."PayrollTimesheetEntries" t
  where t."Username" = l."Username" and t."WorkDate" between r."PeriodStart" and r."PeriodEnd"
) ts
order by l."DisplayName";
