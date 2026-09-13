-- Replaces "Paid Rest Day" (a specific weekday 0-6) with a plain boolean - per "instead of fixing
-- the paid rest day into a specific day can we just make it boolean? so if its true then we will
-- add a day worth of salary into the payrun."
--
-- This drops the whole "exempt/pay one specific weekday" mechanism from
-- supabase_payroll_paid_rest_day_full_pay.sql entirely. Instead: the day-walk goes back to treating
-- every calendar day the same (no day is special-cased), and if HasPaidRestDay is true, one flat
-- extra day's worth of pay is added as its own "Paid Rest Day" Addition line item - using whatever
-- that employee's own daily rate already resolves to (DailyRate for Hourly, the day-walk's
-- resulting effective DailyRate for Salary). This is simpler and matches "add a day worth of salary
-- into the payrun" literally, rather than trying to identify which calendar day to excuse.
--
-- Run this AFTER supabase_payroll_paid_rest_day_full_pay.sql.

alter table public."StaffUsers"
    add column if not exists "HasPaidRestDay" boolean not null default false;

update public."StaffUsers" set "HasPaidRestDay" = true where "PaidRestDay" is not null;

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'CK_StaffUsers_PaidRestDay') then
    alter table public."StaffUsers" drop constraint "CK_StaffUsers_PaidRestDay";
  end if;
end $$;

alter table public."StaffUsers" drop column if exists "PaidRestDay";

-- ---------------------------------------------------------------------------
-- admin_list_staff_users: paid_rest_day int -> has_paid_rest_day boolean.

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
  has_paid_rest_day boolean,
  employee_no text,
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
           "Position"::text, "HomeAddress"::text, "Birthdate", "PhoneNumber"::text, "PaymentMethod"::text, "HireDate", "PayCycle"::text, "MonthlySalary", "PayType"::text, "DailyRate", "HasPaidRestDay", "EmployeeNo"::text,
           count(*) over()
    from public."StaffUsers"
    order by "Username"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_staff_user / admin_update_staff_user: p_paid_rest_day int -> p_has_paid_rest_day
-- boolean, same position.

drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric, int, text);

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
  p_daily_rate numeric default 0,
  p_has_paid_rest_day boolean default false,
  p_employee_no text default null
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

  if nullif(trim(p_employee_no), '') is not null
     and exists (select 1 from public."StaffUsers" where "EmployeeNo" = trim(p_employee_no)) then
    return query select false, 'That employee number is already in use.'::text;
    return;
  end if;

  insert into public."StaffUsers" (
    "Username", "PasswordHash", "DisplayName", "WarehouseName", "SuperUser", "SalesUser", "MonthlySalesTarget", "MustChangePassword",
    "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "PayrollOfficer",
    "Position", "HomeAddress", "Birthdate", "PhoneNumber", "PaymentMethod", "HireDate", "PayCycle", "MonthlySalary", "PayType", "DailyRate", "HasPaidRestDay", "EmployeeNo"
  )
  values (
    p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), nullif(trim(p_warehouse_name), ''), coalesce(p_is_super_user, false), coalesce(p_is_sales_user, false), coalesce(p_monthly_sales_target, 0), coalesce(p_must_change_password, false),
    coalesce(p_is_serial_admin, false), coalesce(p_is_delivery_team, false), coalesce(p_is_online_order_staff, false), coalesce(p_is_production_member, false), coalesce(p_is_payroll_officer, false),
    nullif(trim(p_position), ''), nullif(trim(p_home_address), ''), p_birthdate, nullif(trim(p_phone_number), ''), p_payment_method, p_hire_date, p_pay_cycle, coalesce(p_monthly_salary, 0), coalesce(p_pay_type, 'Salary'), coalesce(p_daily_rate, 0), coalesce(p_has_paid_rest_day, false), nullif(trim(p_employee_no), '')
  );

  return query select true, 'User created.'::text;
end;
$$;

drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric, int, text);

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
  p_daily_rate numeric default 0,
  p_has_paid_rest_day boolean default false,
  p_employee_no text default null
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

  if nullif(trim(p_employee_no), '') is not null
     and exists (select 1 from public."StaffUsers" where "EmployeeNo" = trim(p_employee_no) and "Username" <> p_target_username) then
    return query select false, 'That employee number is already in use.'::text;
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
          "HasPaidRestDay" = coalesce(p_has_paid_rest_day, false),
          "EmployeeNo" = nullif(trim(p_employee_no), ''),
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
          "DailyRate" = coalesce(p_daily_rate, 0),
          "HasPaidRestDay" = coalesce(p_has_paid_rest_day, false),
          "EmployeeNo" = nullif(trim(p_employee_no), '')
      where "Username" = p_target_username;
  end if;

  return query select true, 'User updated.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_employees / admin_update_payroll_profile / admin_create_payroll_employee:
-- same paid_rest_day -> has_paid_rest_day rename.

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
  has_paid_rest_day boolean,
  employee_no text
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
    select "Username"::text, "DisplayName"::text, "IsActive", "PayCycle"::text, "MonthlySalary", "PaymentMethod"::text, "PayType"::text, "DailyRate", "HasPaidRestDay", "EmployeeNo"::text
    from public."StaffUsers"
    order by "DisplayName", "Username";
end;
$$;

drop function if exists public.admin_update_payroll_profile(text, text, text, text, numeric, boolean, text, text, numeric, int, text);

create or replace function public.admin_update_payroll_profile(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_pay_cycle text,
  p_monthly_salary numeric,
  p_is_active boolean default true,
  p_payment_method text default null,
  p_pay_type text default 'Salary',
  p_daily_rate numeric default 0,
  p_has_paid_rest_day boolean default false,
  p_employee_no text default null
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

  if nullif(trim(p_employee_no), '') is not null
     and exists (select 1 from public."StaffUsers" where "EmployeeNo" = trim(p_employee_no) and "Username" <> p_username) then
    return query select false, 'That employee number is already in use.'::text;
    return;
  end if;

  update public."StaffUsers"
    set "PayCycle" = p_pay_cycle,
        "MonthlySalary" = coalesce(p_monthly_salary, 0),
        "IsActive" = coalesce(p_is_active, true),
        "PaymentMethod" = p_payment_method,
        "PayType" = coalesce(p_pay_type, 'Salary'),
        "DailyRate" = coalesce(p_daily_rate, 0),
        "HasPaidRestDay" = coalesce(p_has_paid_rest_day, false),
        "EmployeeNo" = nullif(trim(p_employee_no), '')
    where "Username" = p_username;

  return query select true, 'Payroll profile updated.'::text;
end;
$$;

drop function if exists public.admin_create_payroll_employee(text, text, text, text, text, text, text, date, text, text, date, text, numeric, text, numeric, int, text);

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
  p_daily_rate numeric default 0,
  p_has_paid_rest_day boolean default false,
  p_employee_no text default null
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

  if nullif(trim(p_employee_no), '') is not null
     and exists (select 1 from public."StaffUsers" where "EmployeeNo" = trim(p_employee_no)) then
    return query select false, 'That employee number is already in use.'::text;
    return;
  end if;

  insert into public."StaffUsers" (
    "Username", "PasswordHash", "DisplayName", "SuperUser", "SalesUser", "MustChangePassword",
    "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "PayrollOfficer",
    "Position", "HomeAddress", "Birthdate", "PhoneNumber", "PaymentMethod", "HireDate", "PayCycle", "MonthlySalary", "PayType", "DailyRate", "HasPaidRestDay", "EmployeeNo"
  )
  values (
    p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), false, false, true,
    false, false, false, false, false,
    nullif(trim(p_position), ''), nullif(trim(p_home_address), ''), p_birthdate, nullif(trim(p_phone_number), ''), p_payment_method, p_hire_date, p_pay_cycle, coalesce(p_monthly_salary, 0), coalesce(p_pay_type, 'Salary'), coalesce(p_daily_rate, 0), coalesce(p_has_paid_rest_day, false), nullif(trim(p_employee_no), '')
  );

  return query select true, 'Employee created.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_payroll_run: the day-walk no longer special-cases any weekday (Paid Rest Day is no
-- longer "which day" - so every day in the period is treated the same, undertime and all). Instead,
-- if HasPaidRestDay is true, one flat extra day's pay is added as its own "Paid Rest Day" Addition
-- line item, using whatever daily rate this employee's pay already resolves to that period (Hourly:
-- their StaffUsers.DailyRate; Salary: the day-walk's resulting effective DailyRate, after undertime).

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
      -- calendar month - no day is special-cased here any more (Paid Rest Day is handled below as a
      -- flat addition instead, not by excusing a specific weekday from this walk).
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
      -- separate Undertime/Absence deduction line item any more; a day not worked just isn't
      -- counted as worked. DaysWorked/DailyRate are still stored so the UI can show a "day rate x
      -- days worked" breakdown - DailyRate here is the EFFECTIVE (weighted average) rate for
      -- display, since a blended period has no single true daily rate.
      v_undertime_days := case when v_std_hours_per_day > 0 then v_undertime_hours / v_std_hours_per_day else 0 end;
      v_days_worked := v_expected_days - v_undertime_days;
      v_base_pay := round(v_base_pay, 2);
      v_daily_rate := case when v_days_worked > 0 then round(v_base_pay / v_days_worked, 2) else round(v_period_flat_daily_rate, 2) end;

      update public."PayrollRunLines"
        set "BasePay" = v_base_pay, "DaysWorked" = v_days_worked, "DailyRate" = v_daily_rate,
            "DailyRateBreakdown" = v_daily_rate_breakdown
        where "LineID" = v_line_id;
    end if;

    -- Paid Rest Day: a flat extra day's pay, on top of whatever Base Pay attendance already
    -- resolved to - v_daily_rate at this point holds the right "one day" figure for either branch
    -- (Hourly's own DailyRate column, or Salary's just-computed effective daily rate).
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

grant execute on function public.admin_list_staff_users(text, text, int, int) to anon;
grant execute on function public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric, boolean, text) to anon;
grant execute on function public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric, boolean, text) to anon;
grant execute on function public.admin_list_payroll_employees(text, text) to anon;
grant execute on function public.admin_update_payroll_profile(text, text, text, text, numeric, boolean, text, text, numeric, boolean, text) to anon;
grant execute on function public.admin_create_payroll_employee(text, text, text, text, text, text, text, date, text, text, date, text, numeric, text, numeric, boolean, text) to anon;
grant execute on function public.admin_create_payroll_run(text, text, text, date, date, date) to anon;
