-- Lets a Payroll Officer add a brand-new employee straight from Payroll Setup, per "if the user is
-- a payroll officer he can add new employee under payroll setup." Deliberately a NEW, narrow RPC
-- rather than widening admin_create_staff_user (User Setup's own "+ New Login" RPC, still
-- SuperUser-only via is_admin_authorized) to accept is_payroll_authorized: admin_create_staff_user
-- can grant SuperUser/SalesUser/SerialAdmin/DeliveryTeam/OnlineOrderStaff/ProductionMember/
-- PayrollOfficer/Warehouse - letting a Payroll Officer call that would let them mint their own
-- (or anyone else's) Super User account. admin_create_payroll_employee only ever inserts a plain
-- StaffUsers row with every role flag hardcoded false and MustChangePassword hardcoded true
-- (temporary password, same as the Excel-roster import in
-- supabase_import_employees_from_excel.sql) - a Payroll Officer can create the login + HR/payroll
-- profile, nothing else. A Super User who wants to also flag the new hire as Sales User, assign a
-- Warehouse, etc. still does that afterward in User Setup.
--
-- Run this AFTER supabase_staff_users_payroll_officer_field.sql and
-- supabase_payroll_officer_access.sql (reuses is_payroll_authorized from that file).

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
  p_monthly_salary numeric default 0
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

  insert into public."StaffUsers" (
    "Username", "PasswordHash", "DisplayName", "SuperUser", "SalesUser", "MustChangePassword",
    "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "PayrollOfficer",
    "Position", "HomeAddress", "Birthdate", "PhoneNumber", "PaymentMethod", "HireDate", "PayCycle", "MonthlySalary"
  )
  values (
    p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), false, false, true,
    false, false, false, false, false,
    nullif(trim(p_position), ''), nullif(trim(p_home_address), ''), p_birthdate, nullif(trim(p_phone_number), ''), p_payment_method, p_hire_date, p_pay_cycle, coalesce(p_monthly_salary, 0)
  );

  return query select true, 'Employee created.'::text;
end;
$$;

grant execute on function public.admin_create_payroll_employee(text, text, text, text, text, text, text, date, text, text, date, text, numeric) to anon;
