-- Adds HR profile fields to StaffUsers/User Setup (Position, Home Address, Birthdate, Phone
-- Number, Payment Method, Hire Date) plus surfaces the existing Payroll fields (PayCycle,
-- MonthlySalary - added by supabase_payroll_tables.sql) in the same User Setup form, per "can you
-- implement this to our user setup so we can use this as well on our payroll" - sourced from an
-- employee.xlsx roster the user shared. Nothing changes on the Payroll side: Payroll Setup's
-- admin_update_payroll_profile (supabase_payroll_tables.sql) still edits the exact same
-- PayCycle/MonthlySalary columns, so entering them here is immediately usable by Payroll - both
-- screens are just two entry points onto the same StaffUsers row.
--
-- Follows the same layering pattern as supabase_staff_users_production_member_field.sql etc.:
-- add columns, then drop+recreate admin_list_staff_users/admin_create_staff_user/
-- admin_update_staff_user with the fuller signature. Not added: the Excel's "Flag_F" (always 1,
-- redundant with IsActive) and "Flag_H" (0/1, meaning unclear without a header row) columns - ask
-- before guessing what those represent.
--
-- Run this AFTER supabase_staff_users_table.sql, supabase_staff_users_serial_admin_field.sql,
-- supabase_staff_users_delivery_team_field.sql, supabase_staff_users_online_order_staff_field.sql,
-- supabase_staff_users_production_member_field.sql, and supabase_payroll_tables.sql.

alter table public."StaffUsers"
    add column if not exists "Position" varchar(200);
alter table public."StaffUsers"
    add column if not exists "HomeAddress" varchar(500);
alter table public."StaffUsers"
    add column if not exists "Birthdate" date;
alter table public."StaffUsers"
    add column if not exists "PhoneNumber" varchar(50);
alter table public."StaffUsers"
    add column if not exists "PaymentMethod" varchar(20);
alter table public."StaffUsers"
    add column if not exists "HireDate" date;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'CK_StaffUsers_PaymentMethod'
  ) then
    alter table public."StaffUsers"
      add constraint "CK_StaffUsers_PaymentMethod" check ("PaymentMethod" is null or "PaymentMethod" in ('Cash', 'Digital'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- admin_list_staff_users: add the new HR fields plus PayCycle/MonthlySalary to User Setup's table.

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
    select "Username"::text, "DisplayName"::text, "WarehouseName"::text, "SuperUser", "SalesUser", "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "MonthlySalesTarget", "MustChangePassword", "IsActive", "CreatedAtUtc", "LastLoginAtUtc",
           "Position"::text, "HomeAddress"::text, "Birthdate", "PhoneNumber"::text, "PaymentMethod"::text, "HireDate", "PayCycle"::text, "MonthlySalary",
           count(*) over()
    from public."StaffUsers"
    order by "Username"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_staff_user / admin_update_staff_user: add the same fields as optional params
-- (defaulted so every other existing caller keeps working unchanged), with the same friendly
-- Pay Cycle validation admin_update_payroll_profile already uses.

drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean, boolean, boolean);

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
  p_monthly_salary numeric default 0
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

  insert into public."StaffUsers" (
    "Username", "PasswordHash", "DisplayName", "WarehouseName", "SuperUser", "SalesUser", "MonthlySalesTarget", "MustChangePassword",
    "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember",
    "Position", "HomeAddress", "Birthdate", "PhoneNumber", "PaymentMethod", "HireDate", "PayCycle", "MonthlySalary"
  )
  values (
    p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), nullif(trim(p_warehouse_name), ''), coalesce(p_is_super_user, false), coalesce(p_is_sales_user, false), coalesce(p_monthly_sales_target, 0), coalesce(p_must_change_password, false),
    coalesce(p_is_serial_admin, false), coalesce(p_is_delivery_team, false), coalesce(p_is_online_order_staff, false), coalesce(p_is_production_member, false),
    nullif(trim(p_position), ''), nullif(trim(p_home_address), ''), p_birthdate, nullif(trim(p_phone_number), ''), p_payment_method, p_hire_date, p_pay_cycle, coalesce(p_monthly_salary, 0)
  );

  return query select true, 'User created.'::text;
end;
$$;

drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean, boolean, boolean);

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
  p_monthly_salary numeric default 0
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
          "Position" = nullif(trim(p_position), ''),
          "HomeAddress" = nullif(trim(p_home_address), ''),
          "Birthdate" = p_birthdate,
          "PhoneNumber" = nullif(trim(p_phone_number), ''),
          "PaymentMethod" = p_payment_method,
          "HireDate" = p_hire_date,
          "PayCycle" = p_pay_cycle,
          "MonthlySalary" = coalesce(p_monthly_salary, 0),
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
          "Position" = nullif(trim(p_position), ''),
          "HomeAddress" = nullif(trim(p_home_address), ''),
          "Birthdate" = p_birthdate,
          "PhoneNumber" = nullif(trim(p_phone_number), ''),
          "PaymentMethod" = p_payment_method,
          "HireDate" = p_hire_date,
          "PayCycle" = p_pay_cycle,
          "MonthlySalary" = coalesce(p_monthly_salary, 0)
      where "Username" = p_target_username;
  end if;

  return query select true, 'User updated.'::text;
end;
$$;

grant execute on function public.admin_list_staff_users(text, text, int, int) to anon;
grant execute on function public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric) to anon;
grant execute on function public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean, boolean, boolean, text, text, date, text, text, date, text, numeric) to anon;
