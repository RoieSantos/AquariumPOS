-- Adds job "Roles" to StaffUsers/User Setup, per: "in the staff / employee can we assign their
-- roles - Stand Maker, Tank Maker, Dispatcher, Cashier". Multi-select (text[]) since one employee
-- can hold several (e.g. builds both tanks and stands). These are job-function tags only - they
-- do NOT grant or restrict portal access (that's still the Super User/Delivery Team/Store Manager/
-- etc. flags). The free-text "Position" field stays as-is for the payslip job title.
--
-- Unlike the earlier permission flags, roles are saved through their own small RPC
-- (admin_set_staff_user_roles) instead of growing admin_create_staff_user/admin_update_staff_user
-- by another positional arg - User Setup calls it right after a successful create/update.
-- admin_list_staff_users is recreated only to return staff_roles.
--
-- Run this AFTER supabase_staff_users_conversations_staff_field.sql.

alter table public."StaffUsers"
    add column if not exists "StaffRoles" text[] not null default '{}';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'CK_StaffUsers_StaffRoles'
  ) then
    alter table public."StaffUsers"
      add constraint "CK_StaffUsers_StaffRoles"
      check ("StaffRoles" <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier']::text[]);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- admin_list_staff_users: same as supabase_staff_users_conversations_staff_field.sql plus staff_roles.

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
  is_store_manager boolean,
  is_conversations_staff boolean,
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
  staff_roles text[],
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
    select "Username"::text, "DisplayName"::text, "WarehouseName"::text, "SuperUser", "SalesUser", "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "PayrollOfficer", "StoreManager", "ConversationsStaff", "MonthlySalesTarget", "MustChangePassword", "IsActive", "CreatedAtUtc", "LastLoginAtUtc",
           "Position"::text, "HomeAddress"::text, "Birthdate", "PhoneNumber"::text, "PaymentMethod"::text, "HireDate", "PayCycle"::text, "MonthlySalary", "PayType"::text, "DailyRate", "HasPaidRestDay", "EmployeeNo"::text,
           "StaffRoles",
           count(*) over()
    from public."StaffUsers"
    order by "Username"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_set_staff_user_roles: replaces the user's role list (null/empty = no roles).

create or replace function public.admin_set_staff_user_roles(
  p_admin_username text,
  p_admin_password text,
  p_target_username text,
  p_roles text[]
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_roles text[] := coalesce(
    (select array_agg(distinct r order by r) from unnest(coalesce(p_roles, '{}')) r where nullif(trim(r), '') is not null),
    '{}'
  );
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if not (v_roles <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier']::text[]) then
    return query select false, 'Roles must be Stand Maker, Tank Maker, Dispatcher, or Cashier.'::text;
    return;
  end if;

  update public."StaffUsers" set "StaffRoles" = v_roles where "Username" = p_target_username;

  if not found then
    return query select false, 'That user no longer exists.'::text;
    return;
  end if;

  return query select true, 'Roles updated.'::text;
end;
$$;

grant execute on function public.admin_list_staff_users(text, text, int, int) to anon;
grant execute on function public.admin_set_staff_user_roles(text, text, text, text[]) to anon;
