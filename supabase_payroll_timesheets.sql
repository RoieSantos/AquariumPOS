-- Employee timesheets + overtime, per: "my employees are working on with timesheets. so every
-- employee has 8 hours a day. if they exceed 8 hours they will be subject for overtime."
-- Confirmed scope:
--   - Officer/supervisor enters everyone's daily hours (NOT employee self-service clock-in) - this
--     is a data-entry grid for whoever runs Payroll, not a punch clock.
--   - Per "I want the payroll officer to log it as hours... if works 8 hours, put 8 on the cell" -
--     entries are a plain HOURS number per employee per day (e.g. "8"), not clock in/out times.
--     (An earlier version of this file used TimeIn/TimeOut/BreakMinutes and computed hours from
--     them - reworked before ever shipping into this simpler direct-hours model, since that's what
--     actually matches how the officer wants to fill it in.)
--   - Base Pay stays exactly as before (Monthly Salary / pay cycle, supabase_payroll_tables.sql) -
--     timesheets do NOT replace it. Instead, admin_create_payroll_run now ALSO auto-generates an
--     "Overtime" Addition (hours beyond the standard 8/day x hourly rate x multiplier) and an
--     "Undertime" Deduction (hours short of 8, on days that DO have a timesheet entry) per
--     employee, using the exact same PayrollRunLineItems/recompute_payroll_run_line mechanism as
--     any manually-added line item - so the officer can still edit/delete these afterward on the
--     Payroll Run page exactly like a manual Addition/Deduction, same override philosophy as
--     BasePay itself.
--   - Deliberately NOT auto-detecting absences from missing timesheet entries - a day with no
--     entry could be a rest day, holiday, approved leave, or a real no-show, and this schema has no
--     work-schedule concept to disambiguate. Only days that actually have a timesheet entry (and
--     fall short of the standard hours) generate an Undertime deduction.
--   - Hourly rate = MonthlySalary / (StandardWorkDaysPerMonth x StandardHoursPerDay) - both
--     configurable in Payroll Setup (added to the existing PayrollCutoffSettings singleton row,
--     default 26 days x 8 hours = 208 std hours/month), alongside a configurable
--     OvertimeMultiplier (default 1.25).
--
-- Safe to run whether or not an earlier TimeIn/TimeOut version of this file was already applied -
-- the ALTERs below add the new HoursWorked column and drop the old time columns if present.
--
-- Run this AFTER supabase_payroll_tables.sql, supabase_payroll_ledger.sql,
-- supabase_payroll_officer_access.sql, and supabase_payroll_funding_ledger.sql.

-- ---------------------------------------------------------------------------
-- 1. Overtime settings, folded into the existing PayrollCutoffSettings singleton row rather than a
-- new table - it's still just "payroll-wide settings," same home as the cutoff day-ranges.

alter table public."PayrollCutoffSettings"
    add column if not exists "StandardHoursPerDay" numeric(6, 2) not null default 8;
alter table public."PayrollCutoffSettings"
    add column if not exists "StandardWorkDaysPerMonth" numeric(6, 2) not null default 26;
alter table public."PayrollCutoffSettings"
    add column if not exists "OvertimeMultiplier" numeric(6, 2) not null default 1.25;

-- ---------------------------------------------------------------------------
-- 2. PayrollTimesheetEntries - one row per employee per work date, a plain hours-worked number.
-- Unique per (Username, WorkDate) so re-entering a day edits the existing row.

create table if not exists public."PayrollTimesheetEntries" (
    "TimesheetID" uuid primary key default gen_random_uuid(),
    "Username" varchar(100) not null references public."StaffUsers"("Username"),
    "WorkDate" date not null,
    "HoursWorked" numeric(5, 2) not null default 0 check ("HoursWorked" >= 0 and "HoursWorked" <= 24),
    "Notes" varchar(500),
    "CreatedBy" varchar(100) not null,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now()),
    "UpdatedAtUtc" timestamptz,
    constraint "UQ_PayrollTimesheetEntries_Username_WorkDate" unique ("Username", "WorkDate")
);

-- Rework from an earlier TimeIn/TimeOut design, if that version was already applied.
alter table public."PayrollTimesheetEntries"
    add column if not exists "HoursWorked" numeric(5, 2) not null default 0;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'PayrollTimesheetEntries_HoursWorked_check') then
    alter table public."PayrollTimesheetEntries"
      add constraint "PayrollTimesheetEntries_HoursWorked_check" check ("HoursWorked" >= 0 and "HoursWorked" <= 24);
  end if;
end $$;
alter table public."PayrollTimesheetEntries" drop column if exists "TimeIn";
alter table public."PayrollTimesheetEntries" drop column if exists "TimeOut";
alter table public."PayrollTimesheetEntries" drop column if exists "BreakMinutes";

drop function if exists public.payroll_timesheet_hours(time, time, int);

alter table public."PayrollTimesheetEntries" enable row level security;
revoke all on public."PayrollTimesheetEntries" from anon, authenticated;

create index if not exists "IX_PayrollTimesheetEntries_Username" on public."PayrollTimesheetEntries" ("Username");
create index if not exists "IX_PayrollTimesheetEntries_WorkDate" on public."PayrollTimesheetEntries" ("WorkDate");

comment on table public."PayrollTimesheetEntries" is 'Daily hours worked per employee, entered by the payroll officer/supervisor (not employee self-service). Drives the auto Overtime Addition / Undertime Deduction admin_create_payroll_run posts per run.';

-- ---------------------------------------------------------------------------
-- 3. Timesheet CRUD RPCs (is_payroll_authorized - Super User or Payroll Officer).

drop function if exists public.admin_list_timesheet_entries(text, text, text, date, date, int, int);
drop function if exists public.admin_add_timesheet_entry(text, text, text, date, time, time, int, text);
drop function if exists public.admin_update_timesheet_entry(text, text, uuid, date, time, time, int, text);

create or replace function public.admin_list_timesheet_entries(
  p_admin_username text,
  p_admin_password text,
  p_username text default null,
  p_date_start date default null,
  p_date_end date default null,
  p_page int default 1,
  p_page_size int default 100
)
returns table(
  timesheet_id uuid,
  username text,
  display_name text,
  work_date date,
  hours_worked numeric,
  notes text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 100), 1), 500);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select t."TimesheetID", t."Username"::text, su."DisplayName"::text, t."WorkDate",
           t."HoursWorked", t."Notes"::text,
           count(*) over()
    from public."PayrollTimesheetEntries" t
    join public."StaffUsers" su on su."Username" = t."Username"
    where (p_username is null or t."Username" = p_username)
      and (p_date_start is null or t."WorkDate" >= p_date_start)
      and (p_date_end is null or t."WorkDate" <= p_date_end)
    order by t."WorkDate" desc, su."DisplayName"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

create or replace function public.admin_add_timesheet_entry(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_work_date date,
  p_hours_worked numeric,
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

  if p_username is null or not exists (select 1 from public."StaffUsers" where "Username" = p_username) then
    return query select false, 'That staff login no longer exists.'::text;
    return;
  end if;

  if p_work_date is null then
    return query select false, 'Work date is required.'::text;
    return;
  end if;

  if p_hours_worked is null or p_hours_worked <= 0 or p_hours_worked > 24 then
    return query select false, 'Hours worked must be greater than zero and at most 24.'::text;
    return;
  end if;

  if exists (select 1 from public."PayrollTimesheetEntries" where "Username" = p_username and "WorkDate" = p_work_date) then
    return query select false, 'An entry already exists for this employee on that date - edit it instead.'::text;
    return;
  end if;

  insert into public."PayrollTimesheetEntries" ("Username", "WorkDate", "HoursWorked", "Notes", "CreatedBy")
  values (p_username, p_work_date, p_hours_worked, nullif(trim(p_notes), ''), p_admin_username);

  return query select true, 'Timesheet entry added.'::text;
end;
$$;

create or replace function public.admin_update_timesheet_entry(
  p_admin_username text,
  p_admin_password text,
  p_timesheet_id uuid,
  p_work_date date,
  p_hours_worked numeric,
  p_notes text default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_username text;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select "Username" into v_username from public."PayrollTimesheetEntries" where "TimesheetID" = p_timesheet_id;
  if v_username is null then
    return query select false, 'Timesheet entry not found.'::text;
    return;
  end if;

  if p_work_date is null then
    return query select false, 'Work date is required.'::text;
    return;
  end if;

  if p_hours_worked is null or p_hours_worked <= 0 or p_hours_worked > 24 then
    return query select false, 'Hours worked must be greater than zero and at most 24.'::text;
    return;
  end if;

  if exists (
    select 1 from public."PayrollTimesheetEntries"
    where "Username" = v_username and "WorkDate" = p_work_date and "TimesheetID" <> p_timesheet_id
  ) then
    return query select false, 'This employee already has a different entry for that date.'::text;
    return;
  end if;

  update public."PayrollTimesheetEntries"
    set "WorkDate" = p_work_date,
        "HoursWorked" = p_hours_worked,
        "Notes" = nullif(trim(p_notes), ''),
        "UpdatedAtUtc" = timezone('utc', now())
    where "TimesheetID" = p_timesheet_id;

  return query select true, 'Timesheet entry updated.'::text;
end;
$$;

create or replace function public.admin_delete_timesheet_entry(p_admin_username text, p_admin_password text, p_timesheet_id uuid)
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

  if not exists (select 1 from public."PayrollTimesheetEntries" where "TimesheetID" = p_timesheet_id) then
    return query select false, 'Timesheet entry not found.'::text;
    return;
  end if;

  delete from public."PayrollTimesheetEntries" where "TimesheetID" = p_timesheet_id;

  return query select true, 'Timesheet entry removed.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. admin_get_payroll_cutoff_settings / admin_upsert_payroll_cutoff_settings: add the three new
-- overtime settings columns.

drop function if exists public.admin_get_payroll_cutoff_settings(text, text);

create or replace function public.admin_get_payroll_cutoff_settings(p_admin_username text, p_admin_password text)
returns table(
  cutoff_a_start_day int,
  cutoff_a_end_day int,
  cutoff_a_pay_day int,
  cutoff_a_pay_day_is_last_day_of_month boolean,
  cutoff_b_start_day int,
  cutoff_b_end_day int,
  cutoff_b_pay_day int,
  cutoff_b_pay_day_is_last_day_of_month boolean,
  standard_hours_per_day numeric,
  standard_work_days_per_month numeric,
  overtime_multiplier numeric
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
    select "CutoffAStartDay", "CutoffAEndDay", "CutoffAPayDay", "CutoffAPayDayIsLastDayOfMonth",
           "CutoffBStartDay", "CutoffBEndDay", "CutoffBPayDay", "CutoffBPayDayIsLastDayOfMonth",
           "StandardHoursPerDay", "StandardWorkDaysPerMonth", "OvertimeMultiplier"
    from public."PayrollCutoffSettings"
    where "Id" = 1;
end;
$$;

drop function if exists public.admin_upsert_payroll_cutoff_settings(text, text, int, int, int, boolean, int, int, int, boolean);

create or replace function public.admin_upsert_payroll_cutoff_settings(
  p_admin_username text,
  p_admin_password text,
  p_cutoff_a_start_day int,
  p_cutoff_a_end_day int,
  p_cutoff_a_pay_day int,
  p_cutoff_a_pay_day_is_last_day_of_month boolean,
  p_cutoff_b_start_day int,
  p_cutoff_b_end_day int,
  p_cutoff_b_pay_day int,
  p_cutoff_b_pay_day_is_last_day_of_month boolean,
  p_standard_hours_per_day numeric default 8,
  p_standard_work_days_per_month numeric default 26,
  p_overtime_multiplier numeric default 1.25
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

  if p_cutoff_a_start_day not between 1 and 31 or p_cutoff_a_end_day not between 1 and 31
     or p_cutoff_b_start_day not between 1 and 31 or p_cutoff_b_end_day not between 1 and 31 then
    return query select false, 'Cutoff days must be between 1 and 31.'::text;
    return;
  end if;

  if not p_cutoff_a_pay_day_is_last_day_of_month and (p_cutoff_a_pay_day is null or p_cutoff_a_pay_day not between 1 and 31) then
    return query select false, 'Cutoff A needs a pay day (or use last day of month).'::text;
    return;
  end if;
  if not p_cutoff_b_pay_day_is_last_day_of_month and (p_cutoff_b_pay_day is null or p_cutoff_b_pay_day not between 1 and 31) then
    return query select false, 'Cutoff B needs a pay day (or use last day of month).'::text;
    return;
  end if;

  if coalesce(p_standard_hours_per_day, 0) <= 0 or coalesce(p_standard_work_days_per_month, 0) <= 0 or coalesce(p_overtime_multiplier, 0) <= 0 then
    return query select false, 'Standard hours/day, standard work days/month, and overtime multiplier must all be greater than zero.'::text;
    return;
  end if;

  insert into public."PayrollCutoffSettings" (
    "Id", "CutoffAStartDay", "CutoffAEndDay", "CutoffAPayDay", "CutoffAPayDayIsLastDayOfMonth",
    "CutoffBStartDay", "CutoffBEndDay", "CutoffBPayDay", "CutoffBPayDayIsLastDayOfMonth",
    "StandardHoursPerDay", "StandardWorkDaysPerMonth", "OvertimeMultiplier",
    "UpdatedBy", "UpdatedAtUtc"
  )
  values (
    1, p_cutoff_a_start_day, p_cutoff_a_end_day, p_cutoff_a_pay_day, coalesce(p_cutoff_a_pay_day_is_last_day_of_month, false),
    p_cutoff_b_start_day, p_cutoff_b_end_day, p_cutoff_b_pay_day, coalesce(p_cutoff_b_pay_day_is_last_day_of_month, false),
    coalesce(p_standard_hours_per_day, 8), coalesce(p_standard_work_days_per_month, 26), coalesce(p_overtime_multiplier, 1.25),
    p_admin_username, timezone('utc', now())
  )
  on conflict ("Id") do update
    set "CutoffAStartDay" = excluded."CutoffAStartDay",
        "CutoffAEndDay" = excluded."CutoffAEndDay",
        "CutoffAPayDay" = excluded."CutoffAPayDay",
        "CutoffAPayDayIsLastDayOfMonth" = excluded."CutoffAPayDayIsLastDayOfMonth",
        "CutoffBStartDay" = excluded."CutoffBStartDay",
        "CutoffBEndDay" = excluded."CutoffBEndDay",
        "CutoffBPayDay" = excluded."CutoffBPayDay",
        "CutoffBPayDayIsLastDayOfMonth" = excluded."CutoffBPayDayIsLastDayOfMonth",
        "StandardHoursPerDay" = excluded."StandardHoursPerDay",
        "StandardWorkDaysPerMonth" = excluded."StandardWorkDaysPerMonth",
        "OvertimeMultiplier" = excluded."OvertimeMultiplier",
        "UpdatedBy" = excluded."UpdatedBy",
        "UpdatedAtUtc" = excluded."UpdatedAtUtc";

  return query select true, 'Cutoff settings updated.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. admin_create_payroll_run: same signature/BasePay generation as before, now ALSO scans
-- PayrollTimesheetEntries for each employee within [p_period_start, p_period_end] and posts an
-- Overtime Addition / Undertime Deduction line item per employee who has any, using the standard
-- hours/day, work days/month, and overtime multiplier from PayrollCutoffSettings.

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
  v_hourly_rate numeric;
  v_overtime_hours numeric;
  v_undertime_hours numeric;
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

  insert into public."PayrollRunLines" ("RunID", "Username", "DisplayName", "BasePay", "NetPay")
  select
    v_run_id,
    "Username",
    "DisplayName",
    case p_pay_cycle
      when 'SemiMonthly' then round("MonthlySalary" / 2, 2)
      else round("MonthlySalary" * 12 / 52, 2)
    end,
    case p_pay_cycle
      when 'SemiMonthly' then round("MonthlySalary" / 2, 2)
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

  for v_line_id, v_username, v_monthly_salary in
    select l."LineID", l."Username", su."MonthlySalary"
    from public."PayrollRunLines" l
    join public."StaffUsers" su on su."Username" = l."Username"
    where l."RunID" = v_run_id
  loop
    v_hourly_rate := case when v_std_work_days_per_month > 0 and v_std_hours_per_day > 0
      then v_monthly_salary / (v_std_work_days_per_month * v_std_hours_per_day)
      else 0 end;

    select coalesce(sum(greatest(t."HoursWorked" - v_std_hours_per_day, 0)), 0),
           coalesce(sum(greatest(v_std_hours_per_day - t."HoursWorked", 0)), 0)
      into v_overtime_hours, v_undertime_hours
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

    if v_undertime_hours > 0 and v_hourly_rate > 0 then
      insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
      values (
        v_line_id, 'Deduction',
        'Undertime (' || trim(to_char(v_undertime_hours, 'FM999990.00')) || ' hrs)',
        round(v_undertime_hours * v_hourly_rate, 2)
      );
    end if;

    if v_overtime_hours > 0 or v_undertime_hours > 0 then
      perform public.recompute_payroll_run_line(v_line_id);
    end if;
  end loop;

  return v_run_id;
end;
$$;

grant execute on function public.admin_list_timesheet_entries(text, text, text, date, date, int, int) to anon;
grant execute on function public.admin_add_timesheet_entry(text, text, text, date, numeric, text) to anon;
grant execute on function public.admin_update_timesheet_entry(text, text, uuid, date, numeric, text) to anon;
grant execute on function public.admin_delete_timesheet_entry(text, text, uuid) to anon;
grant execute on function public.admin_get_payroll_cutoff_settings(text, text) to anon;
grant execute on function public.admin_upsert_payroll_cutoff_settings(text, text, int, int, int, boolean, int, int, int, boolean, numeric, numeric, numeric) to anon;
grant execute on function public.admin_create_payroll_run(text, text, text, date, date, date) to anon;
