-- Adds an "Employee No." field to StaffUsers, editable from both User Setup and Payroll Setup
-- (same parity as every other HR/payroll field so far - PayCycle, PaymentMethod, PayType, etc).
-- Free-text (not auto-generated), optional, but enforced unique when set - two employees can't
-- share the same number. Blank is stored as null so multiple employees can each leave it unset.
--
-- Run this AFTER supabase_payroll_paid_rest_day.sql.

alter table public."StaffUsers"
    add column if not exists "EmployeeNo" varchar(50) null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'UQ_StaffUsers_EmployeeNo') then
    alter table public."StaffUsers"
      add constraint "UQ_StaffUsers_EmployeeNo" unique ("EmployeeNo");
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- admin_list_staff_users: add employee_no to User Setup's table.

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
  paid_rest_day int,
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
           "Position"::text, "HomeAddress"::text, "Birthdate", "PhoneNumber"::text, "PaymentMethod"::text, "HireDate", "PayCycle"::text, "MonthlySalary", "PayType"::text, "DailyRate", "PaidRestDay", "EmployeeNo"::text,
           count(*) over()
    from public."StaffUsers"
    order by "Username"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_staff_user / admin_update_staff_user: add p_employee_no, appended at the end.

drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric, int);

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
  p_paid_rest_day int default null,
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

  if p_paid_rest_day is not null and p_paid_rest_day not between 0 and 6 then
    return query select false, 'Paid rest day must be Sunday through Saturday.'::text;
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
    "Position", "HomeAddress", "Birthdate", "PhoneNumber", "PaymentMethod", "HireDate", "PayCycle", "MonthlySalary", "PayType", "DailyRate", "PaidRestDay", "EmployeeNo"
  )
  values (
    p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), nullif(trim(p_warehouse_name), ''), coalesce(p_is_super_user, false), coalesce(p_is_sales_user, false), coalesce(p_monthly_sales_target, 0), coalesce(p_must_change_password, false),
    coalesce(p_is_serial_admin, false), coalesce(p_is_delivery_team, false), coalesce(p_is_online_order_staff, false), coalesce(p_is_production_member, false), coalesce(p_is_payroll_officer, false),
    nullif(trim(p_position), ''), nullif(trim(p_home_address), ''), p_birthdate, nullif(trim(p_phone_number), ''), p_payment_method, p_hire_date, p_pay_cycle, coalesce(p_monthly_salary, 0), coalesce(p_pay_type, 'Salary'), coalesce(p_daily_rate, 0), p_paid_rest_day, nullif(trim(p_employee_no), '')
  );

  return query select true, 'User created.'::text;
end;
$$;

drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric, int);

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
  p_paid_rest_day int default null,
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

  if p_paid_rest_day is not null and p_paid_rest_day not between 0 and 6 then
    return query select false, 'Paid rest day must be Sunday through Saturday.'::text;
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
          "PaidRestDay" = p_paid_rest_day,
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
          "PaidRestDay" = p_paid_rest_day,
          "EmployeeNo" = nullif(trim(p_employee_no), '')
      where "Username" = p_target_username;
  end if;

  return query select true, 'User updated.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_employees / admin_update_payroll_profile / admin_create_payroll_employee:
-- same employee_no field, surfaced in Payroll Setup too.

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
    select "Username"::text, "DisplayName"::text, "IsActive", "PayCycle"::text, "MonthlySalary", "PaymentMethod"::text, "PayType"::text, "DailyRate", "PaidRestDay", "EmployeeNo"::text
    from public."StaffUsers"
    order by "DisplayName", "Username";
end;
$$;

drop function if exists public.admin_update_payroll_profile(text, text, text, text, numeric, boolean, text, text, numeric, int);

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
  p_paid_rest_day int default null,
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

  if p_paid_rest_day is not null and p_paid_rest_day not between 0 and 6 then
    return query select false, 'Paid rest day must be Sunday through Saturday.'::text;
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
        "PaidRestDay" = p_paid_rest_day,
        "EmployeeNo" = nullif(trim(p_employee_no), '')
    where "Username" = p_username;

  return query select true, 'Payroll profile updated.'::text;
end;
$$;

drop function if exists public.admin_create_payroll_employee(text, text, text, text, text, text, text, date, text, text, date, text, numeric, text, numeric, int);

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
  p_paid_rest_day int default null,
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

  if p_paid_rest_day is not null and p_paid_rest_day not between 0 and 6 then
    return query select false, 'Paid rest day must be Sunday through Saturday.'::text;
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
    "Position", "HomeAddress", "Birthdate", "PhoneNumber", "PaymentMethod", "HireDate", "PayCycle", "MonthlySalary", "PayType", "DailyRate", "PaidRestDay", "EmployeeNo"
  )
  values (
    p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), false, false, true,
    false, false, false, false, false,
    nullif(trim(p_position), ''), nullif(trim(p_home_address), ''), p_birthdate, nullif(trim(p_phone_number), ''), p_payment_method, p_hire_date, p_pay_cycle, coalesce(p_monthly_salary, 0), coalesce(p_pay_type, 'Salary'), coalesce(p_daily_rate, 0), p_paid_rest_day, nullif(trim(p_employee_no), '')
  );

  return query select true, 'Employee created.'::text;
end;
$$;

grant execute on function public.admin_list_staff_users(text, text, int, int) to anon;
grant execute on function public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric, int, text) to anon;
grant execute on function public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric, boolean, text, numeric, int, text) to anon;
grant execute on function public.admin_list_payroll_employees(text, text) to anon;
grant execute on function public.admin_update_payroll_profile(text, text, text, text, numeric, boolean, text, text, numeric, int, text) to anon;
grant execute on function public.admin_create_payroll_employee(text, text, text, text, text, text, text, date, text, text, date, text, numeric, text, numeric, int, text) to anon;
