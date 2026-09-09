-- Custom staff login table for the Web Portal (replaces Supabase Auth).
--
-- *** SECURITY NOTE (read before running) ***
-- The Web Portal is a static site with no backend server. This login can
-- only gate the portal's UI - it is NOT a real session mechanism, so it
-- cannot be used by Row Level Security to protect the underlying data
-- tables. See supabase_web_portal_rls_policies.sql, which intentionally
-- opens Transfer_Header, MonthEndHeader, etc. to the public "anon" key so
-- the app keeps working after login. Anyone who extracts the anon key from
-- the portal's JavaScript (trivial via browser dev tools -> view source)
-- can read/write that data directly through the Supabase API, completely
-- bypassing this login screen. This table only stops casual/accidental
-- access through the portal's own UI.
--
-- Run this in the Supabase SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public."StaffUsers" (
    "Username" varchar(100) primary key,
    "PasswordHash" text not null,
    "DisplayName" varchar(200),
    "WarehouseName" varchar(200),
    "SuperUser" boolean not null default false,
    "SalesUser" boolean not null default false,
    "IsActive" boolean not null default true,
    "FailedAttempts" int not null default 0,
    "LockedUntilUtc" timestamptz,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now()),
    "LastLoginAtUtc" timestamptz
);

-- In case this table already existed from an earlier run without these columns.
alter table public."StaffUsers"
    add column if not exists "WarehouseName" varchar(200);
alter table public."StaffUsers"
    add column if not exists "SuperUser" boolean not null default false;
-- "SalesUser" per "add new setup (Boolean) under user setup - Sales User" - flags staff who
-- handle Online Order confirmation/sales duties. Not enforced anywhere yet (Pancake itself owns
-- order confirmation - see CreatedBy/ConfirmedBy in supabase_orders_sync_tables.sql, which log who
-- did it in Pancake, not gate who's allowed to), just tracked here so future features (or manual
-- reporting) have a real flag to check instead of a hardcoded username list.
alter table public."StaffUsers"
    add column if not exists "SalesUser" boolean not null default false;
-- "MonthlySalesTarget" per "I want to add a new field under user setup to setup their target
-- sales" - a per-staff monthly peso target, only meaningful for staff flagged "SalesUser" above.
-- Read by admin_get_sales_by_confirmed_by (supabase_orders_sync_tables.sql) so the Dashboard's
-- Sales by Staff cards can show each staff member's own target + % accomplished, the same way
-- the site-wide "Monthly Sales Target" card already works off a single hardcoded figure.
alter table public."StaffUsers"
    add column if not exists "MonthlySalesTarget" numeric(18, 2) not null default 0;
-- "MustChangePassword" per "add a setup 'Change password' - a boolean field - if true then the
-- user will be asked to change their password upon login". Checked by verify_login() below
-- (returned to the portal so it can force a redirect to change-password.html before the user can
-- reach any other page - see js/auth.js's requireAuth) and cleared automatically once the user
-- successfully sets a new password via change_own_password() below.
alter table public."StaffUsers"
    add column if not exists "MustChangePassword" boolean not null default false;

-- Enable RLS with NO policies defined - this blocks every direct read/write
-- to the table via the REST API (even with the anon key). The only way in
-- is through the verify_login() function below, which runs as
-- SECURITY DEFINER and never returns the password hash itself.
alter table public."StaffUsers" enable row level security;

-- Run this manually (as yourself, in the SQL Editor) to create/reset a staff
-- login, e.g.:
--   insert into public."StaffUsers" ("Username", "PasswordHash", "DisplayName", "WarehouseName", "SuperUser")
--   values ('jane', public.hash_password('ChangeMe123!'), 'Jane Doe', 'Main Warehouse', false)
--   on conflict ("Username") do update set "PasswordHash" = excluded."PasswordHash", "WarehouseName" = excluded."WarehouseName", "SuperUser" = excluded."SuperUser";
-- "WarehouseName" should match the "From Warehouse" / "To Warehouse" text used
-- in Transfer_Header exactly - the portal uses it to filter Transfer Orders to
-- the logged-in user's own warehouse. Leave it null for staff who should see
-- all warehouses (e.g. an admin/owner account).
-- "SuperUser" = true unlocks the portal's "User Setup" page, which lets that
-- staff member create new logins for others. Make at least one account a
-- super user manually here, e.g.:
--   update public."StaffUsers" set "SuperUser" = true where "Username" = 'jane';
create or replace function public.hash_password(plain_password text)
returns text
language sql
set search_path = public, extensions
as $$
  select crypt(plain_password, gen_salt('bf', 10));
$$;

-- Verifies a login attempt and returns only a success flag + display name -
-- never the password hash. Locks the account for 15 minutes after 5
-- consecutive failed attempts to slow down brute-force guessing (the anon
-- key has no other rate limiting of its own).
drop function if exists public.verify_login(text, text);

create or replace function public.verify_login(p_username text, p_password text)
returns table(success boolean, display_name text, warehouse_name text, is_super_user boolean, is_sales_user boolean, must_change_password boolean, message text)
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
  v_must_change_password boolean;
  v_is_active boolean;
  v_locked_until timestamptz;
  v_failed_attempts int;
begin
  select "PasswordHash", "DisplayName"::text, "WarehouseName"::text, "SuperUser", "SalesUser", "MustChangePassword", "IsActive", "LockedUntilUtc", "FailedAttempts"
    into v_password_hash, v_display_name, v_warehouse_name, v_super_user, v_sales_user, v_must_change_password, v_is_active, v_locked_until, v_failed_attempts
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active then
    return query select false, null::text, null::text, false, false, false, 'Invalid username or password.'::text;
    return;
  end if;

  if v_locked_until is not null and v_locked_until > now() then
    return query select false, null::text, null::text, false, false, false, 'Account temporarily locked. Try again later.'::text;
    return;
  end if;

  if v_password_hash = crypt(p_password, v_password_hash) then
    update public."StaffUsers"
      set "FailedAttempts" = 0, "LockedUntilUtc" = null, "LastLoginAtUtc" = timezone('utc', now())
      where "Username" = p_username;
    return query select true, v_display_name, v_warehouse_name, coalesce(v_super_user, false), coalesce(v_sales_user, false), coalesce(v_must_change_password, false), 'OK'::text;
  else
    update public."StaffUsers"
      set "FailedAttempts" = "FailedAttempts" + 1,
          "LockedUntilUtc" = case when "FailedAttempts" + 1 >= 5 then now() + interval '15 minutes' else "LockedUntilUtc" end
      where "Username" = p_username;
    return query select false, null::text, null::text, false, false, false, 'Invalid username or password.'::text;
  end if;
end;
$$;

-- Lets a logged-in staff member set their own new password, re-verifying their CURRENT password
-- first (not the admin trust model - this is self-service, called with the acting user's own
-- credentials, same as verify_login). Always clears "MustChangePassword" on success, whether or
-- not it was set, so a staff member can also voluntarily change their password from Account
-- Settings later without that action re-triggering a forced prompt next login.
drop function if exists public.change_own_password(text, text, text);

create or replace function public.change_own_password(p_username text, p_current_password text, p_new_password text)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
begin
  select "PasswordHash", "IsActive"
    into v_password_hash, v_is_active
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active then
    return query select false, 'Invalid username or password.'::text;
    return;
  end if;

  if v_password_hash <> crypt(p_current_password, v_password_hash) then
    return query select false, 'Current password is incorrect.'::text;
    return;
  end if;

  if p_new_password is null or length(p_new_password) < 6 then
    return query select false, 'New password must be at least 6 characters.'::text;
    return;
  end if;

  update public."StaffUsers"
    set "PasswordHash" = public.hash_password(p_new_password),
        "MustChangePassword" = false,
        "FailedAttempts" = 0,
        "LockedUntilUtc" = null
    where "Username" = p_username;

  return query select true, 'Password changed.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- Super user administration: lets a "SuperUser" staff member create new
-- logins from the portal's User Setup page. There is no real session/JWT
-- (see the security note at the top of this file), so every admin call
-- re-verifies the acting admin's username + password rather than trusting a
-- stored flag - this matches the same trust model as verify_login().

drop function if exists public.is_admin_authorized(text, text);

create or replace function public.is_admin_authorized(p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_super_user boolean;
begin
  select "PasswordHash", "IsActive", "SuperUser"
    into v_password_hash, v_is_active, v_super_user
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active or not coalesce(v_super_user, false) then
    return false;
  end if;

  return v_password_hash = crypt(p_password, v_password_hash);
end;
$$;

-- Same re-verification trust model as is_admin_authorized(), but for pages any active staff
-- member (not just super users) should be able to view - e.g. Online Orders. Deliberately does
-- NOT check the "SuperUser" flag.
drop function if exists public.is_staff_authorized(text, text);

create or replace function public.is_staff_authorized(p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
begin
  select "PasswordHash", "IsActive"
    into v_password_hash, v_is_active
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active then
    return false;
  end if;

  return v_password_hash = crypt(p_password, v_password_hash);
end;
$$;

drop function if exists public.admin_list_staff_users(text, text);
drop function if exists public.admin_list_staff_users(text, text, int, int);

-- p_page/p_page_size (portal-wide pagination) - total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
create or replace function public.admin_list_staff_users(p_admin_username text, p_admin_password text, p_page int default 1, p_page_size int default 50)
returns table(
  username text,
  display_name text,
  warehouse_name text,
  is_super_user boolean,
  is_sales_user boolean,
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
    select "Username"::text, "DisplayName"::text, "WarehouseName"::text, "SuperUser", "SalesUser", "MonthlySalesTarget", "MustChangePassword", "IsActive", "CreatedAtUtc", "LastLoginAtUtc",
           count(*) over()
    from public."StaffUsers"
    order by "Username"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean);
drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean);
drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric);
drop function if exists public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean);

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
  p_must_change_password boolean default false
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

  insert into public."StaffUsers" ("Username", "PasswordHash", "DisplayName", "WarehouseName", "SuperUser", "SalesUser", "MonthlySalesTarget", "MustChangePassword")
  values (p_new_username, public.hash_password(p_new_password), nullif(trim(p_display_name), ''), nullif(trim(p_warehouse_name), ''), coalesce(p_is_super_user, false), coalesce(p_is_sales_user, false), coalesce(p_monthly_sales_target, 0), coalesce(p_must_change_password, false));

  return query select true, 'User created.'::text;
end;
$$;

drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text);
drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean);
drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric);
drop function if exists public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean);

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
  p_must_change_password boolean default false
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
          "IsActive" = coalesce(p_is_active, true)
      where "Username" = p_target_username;
  end if;

  return query select true, 'User updated.'::text;
end;
$$;

-- Only allow the login/admin functions to be called by the portal (anon key).
-- Direct table access stays fully blocked by RLS above. is_admin_authorized()
-- is intentionally NOT granted to anon - it's only callable from inside the
-- other security definer functions above.
revoke all on public."StaffUsers" from anon, authenticated;
grant execute on function public.verify_login(text, text) to anon;
grant execute on function public.change_own_password(text, text, text) to anon;
grant execute on function public.admin_list_staff_users(text, text, int, int) to anon;
grant execute on function public.admin_create_staff_user(text, text, text, text, text, text, boolean, boolean, numeric, boolean) to anon;
grant execute on function public.admin_update_staff_user(text, text, text, text, text, boolean, boolean, text, boolean, numeric, boolean) to anon;
