-- Adds a "Delivery Team" flag to StaffUsers, per "create me a new field on the user setup.
-- Delivery team - if the user is on Delivery team they can only see the Delivery calendar that
-- is all". Unlike SalesUser/SerialAdmin (which only narrow what's VISIBLE elsewhere), this one is
-- an exclusive lockdown - a Delivery Team account is confined to delivery.html and nowhere else,
-- enforced in js/auth.js's requireAuth() (every authenticated page calls it, so this can't be
-- bypassed by bookmarking/typing a different URL directly).
--
-- Run this AFTER supabase_staff_users_table.sql (layers on top of the same StaffUsers
-- table/functions, following the same pattern as "SerialAdmin" - see
-- supabase_staff_users_serial_admin_field.sql).

alter table public."StaffUsers"
    add column if not exists "DeliveryTeam" boolean not null default false;

-- ---------------------------------------------------------------------------
-- verify_login: add is_delivery_team to the returned columns so the portal session (see
-- attemptLogin/refreshPortalSession in js/auth.js) knows to lock this account to delivery.html.

drop function if exists public.verify_login(text, text);

create or replace function public.verify_login(p_username text, p_password text)
returns table(success boolean, display_name text, warehouse_name text, is_super_user boolean, is_sales_user boolean, is_serial_admin boolean, is_delivery_team boolean, must_change_password boolean, message text)
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
  v_must_change_password boolean;
  v_is_active boolean;
  v_locked_until timestamptz;
  v_failed_attempts int;
begin
  select "PasswordHash", "DisplayName"::text, "WarehouseName"::text, "SuperUser", "SalesUser", "SerialAdmin", "DeliveryTeam", "MustChangePassword", "IsActive", "LockedUntilUtc", "FailedAttempts"
    into v_password_hash, v_display_name, v_warehouse_name, v_super_user, v_sales_user, v_serial_admin, v_delivery_team, v_must_change_password, v_is_active, v_locked_until, v_failed_attempts
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active then
    return query select false, null::text, null::text, false, false, false, false, false, 'Invalid username or password.'::text;
    return;
  end if;

  if v_locked_until is not null and v_locked_until > now() then
    return query select false, null::text, null::text, false, false, false, false, false, 'Account temporarily locked. Try again later.'::text;
    return;
  end if;

  if v_password_hash = crypt(p_password, v_password_hash) then
    update public."StaffUsers"
      set "FailedAttempts" = 0, "LockedUntilUtc" = null, "LastLoginAtUtc" = timezone('utc', now())
      where "Username" = p_username;
    return query select true, v_display_name, v_warehouse_name, coalesce(v_super_user, false), coalesce(v_sales_user, false), coalesce(v_serial_admin, false), coalesce(v_delivery_team, false), coalesce(v_must_change_password, false), 'OK'::text;
  else
    update public."StaffUsers"
      set "FailedAttempts" = "FailedAttempts" + 1,
          "LockedUntilUtc" = case when "FailedAttempts" + 1 >= 5 then now() + interval '15 minutes' else "LockedUntilUtc" end
      where "Username" = p_username;
    return query select false, null::text, null::text, false, false, false, false, false, 'Invalid username or password.'::text;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_staff_users: add is_delivery_team to User Setup's table.

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
    select "Username"::text, "DisplayName"::text, "WarehouseName"::text, "SuperUser", "SalesUser", "SerialAdmin", "DeliveryTeam", "MonthlySalesTarget", "MustChangePassword", "IsActive", "CreatedAtUtc", "LastLoginAtUtc",
           count(*) over()
    from public."StaffUsers"
    order by "Username"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_staff_user / admin_update_staff_user: add p_is_delivery_team.

drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean);

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
  p_is_delivery_team boolean default false
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

  insert into public."StaffUsers" ("Username", "PasswordHash", "DisplayName", "WarehouseName", "SuperUser", "SalesUser", "MonthlySalesTarget", "MustChangePassword", "SerialAdmin", "DeliveryTeam")
  values (p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), nullif(trim(p_warehouse_name), ''), coalesce(p_is_super_user, false), coalesce(p_is_sales_user, false), coalesce(p_monthly_sales_target, 0), coalesce(p_must_change_password, false), coalesce(p_is_serial_admin, false), coalesce(p_is_delivery_team, false));

  return query select true, 'User created.'::text;
end;
$$;

drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean);

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
  p_is_delivery_team boolean default false
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
          "DeliveryTeam" = coalesce(p_is_delivery_team, false)
      where "Username" = p_target_username;
  end if;

  return query select true, 'User updated.'::text;
end;
$$;

grant execute on function public.verify_login(text, text) to anon;
grant execute on function public.admin_list_staff_users(text, text, int, int) to anon;
grant execute on function public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean, boolean, boolean) to anon;
grant execute on function public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean, boolean, boolean) to anon;
