-- Adds a "Production Member" flag to StaffUsers, per direct request to be able to assign an
-- online order to a specific team member who builds it (custom aquariums/stands/sumps etc).
--
-- Unlike "Delivery Team"/"Online Order Staff" (which are exclusive lockdowns confining an account
-- to one page - see supabase_staff_users_delivery_team_field.sql /
-- supabase_staff_users_online_order_staff_field.sql), this is a plain TAG flag, same shape as
-- "SalesUser"/"SerialAdmin" - it does NOT confine the account anywhere in js/auth.js's
-- requireAuth(). It only controls who shows up in the Online Orders "Assigned To" dropdown (see
-- staff_list_production_members in supabase_online_order_production_assignment.sql) - a Production
-- Member keeps normal portal access otherwise.
--
-- Run this AFTER supabase_staff_users_table.sql (layers on top of the same StaffUsers
-- table/functions, following the same pattern as "DeliveryTeam"/"OnlineOrderStaff").

alter table public."StaffUsers"
    add column if not exists "ProductionMember" boolean not null default false;

-- ---------------------------------------------------------------------------
-- verify_login: add is_production_member to the returned columns, same as every other StaffUsers
-- flag, even though nothing currently branches on it at login - keeps this function's column set
-- a complete mirror of the table's flags for any future use.

drop function if exists public.verify_login(text, text);

create or replace function public.verify_login(p_username text, p_password text)
returns table(success boolean, display_name text, warehouse_name text, is_super_user boolean, is_sales_user boolean, is_serial_admin boolean, is_delivery_team boolean, is_online_order_staff boolean, is_production_member boolean, must_change_password boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_display_name text;
  v_warehouse_name text;
  v_super_user boolean;
  v_sales_user boolean;
  v_serial_admin boolean;
  v_delivery_team boolean;
  v_online_order_staff boolean;
  v_production_member boolean;
  v_must_change_password boolean;
  v_is_active boolean;
  v_locked_until timestamptz;
  v_failed_attempts int;
begin
  select "PasswordHash", "DisplayName"::text, "WarehouseName"::text, "SuperUser", "SalesUser", "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "MustChangePassword", "IsActive", "LockedUntilUtc", "FailedAttempts"
    into v_password_hash, v_display_name, v_warehouse_name, v_super_user, v_sales_user, v_serial_admin, v_delivery_team, v_online_order_staff, v_production_member, v_must_change_password, v_is_active, v_locked_until, v_failed_attempts
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active then
    return query select false, null::text, null::text, false, false, false, false, false, false, false, 'Invalid username or password.'::text;
    return;
  end if;

  if v_locked_until is not null and v_locked_until > now() then
    return query select false, null::text, null::text, false, false, false, false, false, false, false, 'Account temporarily locked. Try again later.'::text;
    return;
  end if;

  if v_password_hash = crypt(p_password, v_password_hash) then
    update public."StaffUsers"
      set "FailedAttempts" = 0, "LockedUntilUtc" = null, "LastLoginAtUtc" = timezone('utc', now())
      where "Username" = p_username;
    return query select true, v_display_name, v_warehouse_name, coalesce(v_super_user, false), coalesce(v_sales_user, false), coalesce(v_serial_admin, false), coalesce(v_delivery_team, false), coalesce(v_online_order_staff, false), coalesce(v_production_member, false), coalesce(v_must_change_password, false), 'OK'::text;
  else
    update public."StaffUsers"
      set "FailedAttempts" = "FailedAttempts" + 1,
          "LockedUntilUtc" = case when "FailedAttempts" + 1 >= 5 then now() + interval '15 minutes' else "LockedUntilUtc" end
      where "Username" = p_username;
    return query select false, null::text, null::text, false, false, false, false, false, false, false, 'Invalid username or password.'::text;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_staff_users: add is_production_member to User Setup's table.

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
           count(*) over()
    from public."StaffUsers"
    order by "Username"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_staff_user / admin_update_staff_user: add p_is_production_member.

drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean);

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
  p_is_production_member boolean default false
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

  insert into public."StaffUsers" ("Username", "PasswordHash", "DisplayName", "WarehouseName", "SuperUser", "SalesUser", "MonthlySalesTarget", "MustChangePassword", "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember")
  values (p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), nullif(trim(p_warehouse_name), ''), coalesce(p_is_super_user, false), coalesce(p_is_sales_user, false), coalesce(p_monthly_sales_target, 0), coalesce(p_must_change_password, false), coalesce(p_is_serial_admin, false), coalesce(p_is_delivery_team, false), coalesce(p_is_online_order_staff, false), coalesce(p_is_production_member, false));

  return query select true, 'User created.'::text;
end;
$$;

drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean);

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
  p_is_production_member boolean default false
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
          "ProductionMember" = coalesce(p_is_production_member, false)
      where "Username" = p_target_username;
  end if;

  return query select true, 'User updated.'::text;
end;
$$;

grant execute on function public.verify_login(text, text) to anon;
grant execute on function public.admin_list_staff_users(text, text, int, int) to anon;
grant execute on function public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean, boolean, boolean) to anon;
grant execute on function public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean, boolean) to anon;
