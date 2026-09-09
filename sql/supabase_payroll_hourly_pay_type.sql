-- Hourly Base Pay from Timesheets, per: "i want you to compute base on the hour.. an employee fix
-- rate per day / 8 hours a day if possible. then multiply to whatever hours they render per day."
--
-- Adds a per-employee "Pay Type" (Salary - default, unchanged behavior for every existing
-- employee - or Hourly) plus a "Daily Rate" (the "fix rate per day"). For a Salary employee,
-- nothing changes: Base Pay is still MonthlySalary / pay cycle, with Timesheets only adding the
-- Overtime/Undertime adjustment on top (supabase_payroll_timesheets.sql). For an Hourly employee,
-- admin_create_payroll_run now computes Base Pay directly from their timesheet entries in the
-- run's period:
--   hourly rate  = DailyRate / StandardHoursPerDay   (the "/8 hours a day" from the request -
--                  StandardHoursPerDay is the same Overtime Settings value from Payroll Setup)
--   regular pay  = sum(min(HoursWorked, StandardHoursPerDay) per day) x hourly rate
--   overtime pay = sum(max(HoursWorked - StandardHoursPerDay, 0) per day) x hourly rate x
--                  OvertimeMultiplier  (posted as an Addition, same mechanism as Salary employees)
-- No separate Undertime deduction for Hourly employees - unlike a Salary employee (who has a fixed
-- amount an Undertime day reduces), an Hourly employee's Base Pay is already exactly proportional
-- to the hours they actually logged, so a short day already pays less; deducting again would be
-- double-counting.
--
-- Important behavioral difference from Salary: an Hourly employee with NO timesheet entries in the
-- run's period gets Base Pay of exactly 0 (no flat amount to fall back on) - Timesheets stop being
-- optional the moment someone is flagged Hourly.
--
-- Run this AFTER supabase_staff_users_payroll_officer_field.sql, supabase_payroll_officer_access.sql,
-- supabase_payroll_officer_create_employee.sql, supabase_payroll_funding_ledger.sql, and
-- supabase_payroll_timesheets.sql.

alter table public."StaffUsers"
    add column if not exists "PayType" varchar(20) not null default 'Salary';
alter table public."StaffUsers"
    add column if not exists "DailyRate" numeric(18, 2) not null default 0;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'CK_StaffUsers_PayType') then
    alter table public."StaffUsers"
      add constraint "CK_StaffUsers_PayType" check ("PayType" in ('Salary', 'Hourly'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- admin_list_staff_users: add pay_type/daily_rate to User Setup's table.

drop function if exists public.admin_list_staff_users(text, text, int, int);

create or replace function public.admin_list_staff_users(p_admin_username text, p_admin_password text, p_page int default 1, p_page_size int default 50)
returns table(
  username text,
  display_name text,
  warehouse_name text,
  is_super_user boolean,
  is_sales_user boolean,
  is_serial_admin boolean,
  is_delivery_team boolean,
  is_online_order_staff boolean,
  is_production_member boolean,
  is_payroll_officer boolean,
  monthly_sales_target numeric,
  must_change_password boolean,
  is_active boolean,
  created_at_utc timestamptz,
  last_login_at_utc timestamptz,
  job_position text,
  home_address text,
  birthdate date,
  phone_number text,
  payment_method text,
  hire_date date,
  pay_cycle text,
  monthly_salary numeric,
  pay_type text,
  daily_rate numeric,
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
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "Username"::text, "DisplayName"::text, "WarehouseName"::text, "SuperUser", "SalesUser", "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "PayrollOfficer", "MonthlySalesTarget", "MustChangePassword", "IsActive", "CreatedAtUtc", "LastLoginAtUtc",
           "Position"::text, "HomeAddress"::text, "Birthdate", "PhoneNumber"::text, "PaymentMethod"::text, "HireDate", "PayCycle"::text, "MonthlySalary", "PayType"::text, "DailyRate",
           count(*) over()
    from public."StaffUsers"
    order by "Username"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_staff_user / admin_update_staff_user: add p_pay_type/p_daily_rate, appended at the
-- end of the current signature (same incremental-append pattern as every prior field).

drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean);

create or replace function public.admin_create_staff_user(
  p_admin_username text,
  p_admin_password text,
  p_new_username text,
  p_new_password text,
  p_display_name text,
  p_warehouse_name text,
  p_is_super_user boolean,
  p_is_sales_user boolean default false,
  p_monthly_sales_target numeric default 0,
  p_must_change_password boolean default false,
  p_is_serial_admin boolean default false,
  p_is_delivery_team boolean default false,
  p_is_online_order_staff boolean default false,
  p_is_production_member boolean default false,
  p_position text default null,
  p_home_address text default null,
  p_birthdate date default null,
  p_phone_number text default null,
  p_payment_method text default null,
  p_hire_date date default null,
  p_pay_cycle text default null,
  p_monthly_salary numeric default 0,
  p_is_payroll_officer boolean default false,
  p_pay_type text default 'Salary',
  p_daily_rate numeric default 0
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_new_username is null or trim(p_new_username) = '' then
    return query select false, 'Username is required.'::text;
    return;
  end if;

  if p_new_password is null or length(p_new_password) < 6 then
    return query select false, 'Password must be at least 6 characters.'::text;
    return;
  end if;

  if exists (select 1 from public."StaffUsers" where "Username" = p_new_username) then
    return query select false, 'That username already exists.'::text;
    return;
  end if;

  if p_pay_cycle is not null and p_pay_cycle not in ('SemiMonthly', 'Weekly') then
    return query select false, 'Pay cycle must be Semi-Monthly or Weekly.'::text;
    return;
  end if;

  if p_payment_method is not null and p_payment_method not in ('Cash', 'Digital') then
    return query select false, 'Payment method must be Cash or Digital.'::text;
    return;
  end if;

  if coalesce(p_pay_type, 'Salary') not in ('Salary', 'Hourly') then
    return query select false, 'Pay type must be Salary or Hourly.'::text;
    return;
  end if;

  insert into public."StaffUsers" (
    "Username", "PasswordHash", "DisplayName", "WarehouseName", "SuperUser", "SalesUser", "MonthlySalesTarget", "MustChangePassword",
    "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "PayrollOfficer",
    "Position", "HomeAddress", "Birthdate", "PhoneNumber", "PaymentMethod", "HireDate", "PayCycle", "MonthlySalary", "PayType", "DailyRate"
  )
  values (
    p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), nullif(trim(p_warehouse_name), ''), coalesce(p_is_super_user, false), coalesce(p_is_sales_user, false), coalesce(p_monthly_sales_target, 0), coalesce(p_must_change_password, false),
    coalesce(p_is_serial_admin, false), coalesce(p_is_delivery_team, false), coalesce(p_is_online_order_staff, false), coalesce(p_is_production_member, false), coalesce(p_is_payroll_officer, false),
    nullif(trim(p_position), ''), nullif(trim(p_home_address), ''), p_birthdate, nullif(trim(p_phone_number), ''), p_payment_method, p_hire_date, p_pay_cycle, coalesce(p_monthly_salary, 0), coalesce(p_pay_type, 'Salary'), coalesce(p_daily_rate, 0)
  );

  return query select true, 'User created.'::text;
end;
$$;

drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean);

create or replace function public.admin_update_staff_user(
  p_admin_username text,
  p_admin_password text,
  p_target_username text,
  p_display_name text,
  p_warehouse_name text,
  p_is_super_user boolean,
  p_is_active boolean,
  p_new_password text default null,
  p_is_sales_user boolean default false,
  p_monthly_sales_target numeric default 0,
  p_must_change_password boolean default false,
  p_is_serial_admin boolean default false,
  p_is_delivery_team boolean default false,
  p_is_online_order_staff boolean default false,
  p_is_production_member boolean default false,
  p_position text default null,
  p_home_address text default null,
  p_birthdate date default null,
  p_phone_number text default null,
  p_payment_method text default null,
  p_hire_date date default null,
  p_pay_cycle text default null,
  p_monthly_salary numeric default 0,
  p_is_payroll_officer boolean default false,
  p_pay_type text default 'Salary',
  p_daily_rate numeric default 0
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_target_username is null or trim(p_target_username) = '' then
    return query select false, 'Username is required.'::text;
    return;
  end if;

  if not exists (select 1 from public."StaffUsers" where "Username" = p_target_username) then
    return query select false, 'That user no longer exists.'::text;
    return;
  end if;

  if p_pay_cycle is not null and p_pay_cycle not in ('SemiMonthly', 'Weekly') then
    return query select false, 'Pay cycle must be Semi-Monthly or Weekly.'::text;
    return;
  end if;

  if p_payment_method is not null and p_payment_method not in ('Cash', 'Digital') then
    return query select false, 'Payment method must be Cash or Digital.'::text;
    return;
  end if;

  if coalesce(p_pay_type, 'Salary') not in ('Salary', 'Hourly') then
    return query select false, 'Pay type must be Salary or Hourly.'::text;
    return;
  end if;

  -- Optional password reset: only touched (and re-hashed) when a new password is supplied.
  if p_new_password is not null and trim(p_new_password) <> '' then
    if length(p_new_password) < 6 then
      return query select false, 'Password must be at least 6 characters.'::text;
      return;
    end if;

    update public."StaffUsers"
      set "DisplayName" = nullif(trim(p_display_name), ''),
          "WarehouseName" = nullif(trim(p_warehouse_name), ''),
          "SuperUser" = coalesce(p_is_super_user, false),
          "SalesUser" = coalesce(p_is_sales_user, false),
          "MonthlySalesTarget" = coalesce(p_monthly_sales_target, 0),
          "MustChangePassword" = coalesce(p_must_change_password, false),
          "IsActive" = coalesce(p_is_active, true),
          "SerialAdmin" = coalesce(p_is_serial_admin, false),
          "DeliveryTeam" = coalesce(p_is_delivery_team, false),
          "OnlineOrderStaff" = coalesce(p_is_online_order_staff, false),
          "ProductionMember" = coalesce(p_is_production_member, false),
          "PayrollOfficer" = coalesce(p_is_payroll_officer, false),
          "Position" = nullif(trim(p_position), ''),
          "HomeAddress" = nullif(trim(p_home_address), ''),
          "Birthdate" = p_birthdate,
          "PhoneNumber" = nullif(trim(p_phone_number), ''),
          "PaymentMethod" = p_payment_method,
          "HireDate" = p_hire_date,
          "PayCycle" = p_pay_cycle,
          "MonthlySalary" = coalesce(p_monthly_salary, 0),
          "PayType" = coalesce(p_pay_type, 'Salary'),
          "DailyRate" = coalesce(p_daily_rate, 0),
          "PasswordHash" = public.hash_password(p_new_password),
          "FailedAttempts" = 0,
          "LockedUntilUtc" = null
      where "Username" = p_target_username;
  else
    update public."StaffUsers"
      set "DisplayName" = nullif(trim(p_display_name), ''),
          "WarehouseName" = nullif(trim(p_warehouse_name), ''),
          "SuperUser" = coalesce(p_is_super_user, false),
          "SalesUser" = coalesce(p_is_sales_user, false),
          "MonthlySalesTarget" = coalesce(p_monthly_sales_target, 0),
          "MustChangePassword" = coalesce(p_must_change_password, false),
          "IsActive" = coalesce(p_is_active, true),
          "SerialAdmin" = coalesce(p_is_serial_admin, false),
          "DeliveryTeam" = coalesce(p_is_delivery_team, false),
          "OnlineOrderStaff" = coalesce(p_is_online_order_staff, false),
          "ProductionMember" = coalesce(p_is_production_member, false),
          "PayrollOfficer" = coalesce(p_is_payroll_officer, false),
          "Position" = nullif(trim(p_position), ''),
          "HomeAddress" = nullif(trim(p_home_address), ''),
          "Birthdate" = p_birthdate,
          "PhoneNumber" = nullif(trim(p_phone_number), ''),
          "PaymentMethod" = p_payment_method,
          "HireDate" = p_hire_date,
          "PayCycle" = p_pay_cycle,
          "MonthlySalary" = coalesce(p_monthly_salary, 0),
          "PayType" = coalesce(p_pay_type, 'Salary'),
          "DailyRate" = coalesce(p_daily_rate, 0)
      where "Username" = p_target_username;
  end if;

  return query select true, 'User updated.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_employees / admin_update_payroll_profile / admin_create_payroll_employee:
-- same pay_type/daily_rate fields, surfaced in Payroll Setup too.

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
  daily_rate numeric
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
    select "Username"::text, "DisplayName"::text, "IsActive", "PayCycle"::text, "MonthlySalary", "PaymentMethod"::text, "PayType"::text, "DailyRate"
    from public."StaffUsers"
    order by "DisplayName", "Username";
end;
$$;

drop function if exists public.admin_update_payroll_profile(text, text, text, text, numeric, boolean, text);

create or replace function public.admin_update_payroll_profile(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_pay_cycle text,
  p_monthly_salary numeric,
  p_is_active boolean default true,
  p_payment_method text default null,
  p_pay_type text default 'Salary',
  p_daily_rate numeric default 0
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

  if p_pay_cycle is not null and p_pay_cycle not in ('SemiMonthly', 'Weekly') then
    return query select false, 'Pay cycle must be Semi-Monthly or Weekly.'::text;
    return;
  end if;

  if p_payment_method is not null and p_payment_method not in ('Cash', 'Digital') then
    return query select false, 'Payment method must be Cash or Digital.'::text;
    return;
  end if;

  if coalesce(p_pay_type, 'Salary') not in ('Salary', 'Hourly') then
    return query select false, 'Pay type must be Salary or Hourly.'::text;
    return;
  end if;

  if not exists (select 1 from public."StaffUsers" where "Username" = p_username) then
    return query select false, 'That staff login no longer exists.'::text;
    return;
  end if;

  update public."StaffUsers"
    set "PayCycle" = p_pay_cycle,
        "MonthlySalary" = coalesce(p_monthly_salary, 0),
        "IsActive" = coalesce(p_is_active, true),
        "PaymentMethod" = p_payment_method,
        "PayType" = coalesce(p_pay_type, 'Salary'),
        "DailyRate" = coalesce(p_daily_rate, 0)
    where "Username" = p_username;

  return query select true, 'Payroll profile updated.'::text;
end;
$$;

drop function if exists public.admin_create_payroll_employee(text, text, text, text, text, text, text, date, text, text, date, text, numeric);

create or replace function public.admin_create_payroll_employee(
  p_admin_username text,
  p_admin_password text,
  p_new_username text,
  p_new_password text,
  p_display_name text,
  p_position text default null,
  p_home_address text default null,
  p_birthdate date default null,
  p_phone_number text default null,
  p_payment_method text default null,
  p_hire_date date default null,
  p_pay_cycle text default null,
  p_monthly_salary numeric default 0,
  p_pay_type text default 'Salary',
  p_daily_rate numeric default 0
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

  if p_new_username is null or trim(p_new_username) = '' then
    return query select false, 'Username is required.'::text;
    return;
  end if;

  if p_new_password is null or length(p_new_password) < 6 then
    return query select false, 'Password must be at least 6 characters.'::text;
    return;
  end if;

  if exists (select 1 from public."StaffUsers" where "Username" = p_new_username) then
    return query select false, 'That username already exists.'::text;
    return;
  end if;

  if p_pay_cycle is not null and p_pay_cycle not in ('SemiMonthly', 'Weekly') then
    return query select false, 'Pay cycle must be Semi-Monthly or Weekly.'::text;
    return;
  end if;

  if p_payment_method is not null and p_payment_method not in ('Cash', 'Digital') then
    return query select false, 'Payment method must be Cash or Digital.'::text;
    return;
  end if;

  if coalesce(p_pay_type, 'Salary') not in ('Salary', 'Hourly') then
    return query select false, 'Pay type must be Salary or Hourly.'::text;
    return;
  end if;

  insert into public."StaffUsers" (
    "Username", "PasswordHash", "DisplayName", "SuperUser", "SalesUser", "MustChangePassword",
    "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "PayrollOfficer",
    "Position", "HomeAddress", "Birthdate", "PhoneNumber", "PaymentMethod", "HireDate", "PayCycle", "MonthlySalary", "PayType", "DailyRate"
  )
  values (
    p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), false, false, true,
    false, false, false, false, false,
    nullif(trim(p_position), ''), nullif(trim(p_home_address), ''), p_birthdate, nullif(trim(p_phone_number), ''), p_payment_method, p_hire_date, p_pay_cycle, coalesce(p_monthly_salary, 0), coalesce(p_pay_type, 'Salary'), coalesce(p_daily_rate, 0)
  );

  return query select true, 'Employee created.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_payroll_run: same signature as before. Salary employees are computed exactly as
-- before (unchanged). Hourly employees get Base Pay computed directly from their timesheet hours
-- in the run's period instead of from MonthlySalary.

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
    end if;
  end loop;

  return v_run_id;
end;
$$;

grant execute on function public.admin_list_staff_users(text, text, int, int) to anon;
grant execute on function public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric) to anon;
grant execute on function public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric) to anon;
grant execute on function public.admin_list_payroll_employees(text, text) to anon;
grant execute on function public.admin_update_payroll_profile(text, text, text, text, numeric, boolean, text, text, numeric) to anon;
grant execute on function public.admin_create_payroll_employee(text, text, text, text, text, text, text, date, text, text, date, text, numeric, text, numeric) to anon;
grant execute on function public.admin_create_payroll_run(text, text, text, date, date, date) to anon;
