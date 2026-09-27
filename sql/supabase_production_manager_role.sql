-- Adds a "Production Manager" Staff Role and makes order assignment theirs, per "i want the
-- production manager to assign the order to tank maker and stand maker" / "instead of building
-- new page.. can we only use the online orders instead but i want production manager can assign
-- only". Assignment stays on the Online Orders document (Assignment FastTab) - no separate page.
--
-- - StaffRoles: 'ProductionManager' joins StandMaker/TankMaker/Dispatcher/Cashier (ticked in User
--   Setup > Employee > Roles, same as the others).
-- - verify_login: now also returns staff_roles, so the portal session (js/auth.js) knows who is a
--   Production Manager - Online Orders only enables the assignment dropdowns for them.
-- - admin_assign_online_order_maker: setting/clearing a Tank Maker, Stand Maker OR Dispatcher now
--   requires the CALLER to be a Super User or a Production Manager (was: any active staff).
--
-- Run this AFTER supabase_online_order_dispatcher.sql (and therefore after
-- supabase_staff_users_staff_roles.sql / supabase_staff_users_conversations_staff_field.sql).

-- ---------------------------------------------------------------------------
-- Allowed roles

alter table public."StaffUsers" drop constraint if exists "CK_StaffUsers_StaffRoles";
alter table public."StaffUsers"
  add constraint "CK_StaffUsers_StaffRoles"
  check ("StaffRoles" <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier', 'ProductionManager']::text[]);

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

  if not (v_roles <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier', 'ProductionManager']::text[]) then
    return query select false, 'Roles must be Stand Maker, Tank Maker, Dispatcher, Cashier, or Production Manager.'::text;
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

grant execute on function public.admin_set_staff_user_roles(text, text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- verify_login: same as supabase_staff_users_conversations_staff_field.sql plus staff_roles.

drop function if exists public.verify_login(text, text);

create or replace function public.verify_login(p_username text, p_password text)
returns table(success boolean, display_name text, warehouse_name text, is_super_user boolean, is_sales_user boolean, is_serial_admin boolean, is_delivery_team boolean, is_online_order_staff boolean, is_production_member boolean, is_payroll_officer boolean, is_store_manager boolean, is_conversations_staff boolean, must_change_password boolean, message text, staff_roles text[])
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
  v_payroll_officer boolean;
  v_store_manager boolean;
  v_conversations_staff boolean;
  v_must_change_password boolean;
  v_is_active boolean;
  v_locked_until timestamptz;
  v_failed_attempts int;
  v_staff_roles text[];
begin
  select "PasswordHash", "DisplayName"::text, "WarehouseName"::text, "SuperUser", "SalesUser", "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "PayrollOfficer", "StoreManager", "ConversationsStaff", "MustChangePassword", "IsActive", "LockedUntilUtc", "FailedAttempts", "StaffRoles"
    into v_password_hash, v_display_name, v_warehouse_name, v_super_user, v_sales_user, v_serial_admin, v_delivery_team, v_online_order_staff, v_production_member, v_payroll_officer, v_store_manager, v_conversations_staff, v_must_change_password, v_is_active, v_locked_until, v_failed_attempts, v_staff_roles
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active then
    return query select false, null::text, null::text, false, false, false, false, false, false, false, false, false, false, 'Invalid username or password.'::text, '{}'::text[];
    return;
  end if;

  if v_locked_until is not null and v_locked_until > now() then
    return query select false, null::text, null::text, false, false, false, false, false, false, false, false, false, false, 'Account temporarily locked. Try again later.'::text, '{}'::text[];
    return;
  end if;

  if v_password_hash = crypt(p_password, v_password_hash) then
    update public."StaffUsers"
      set "FailedAttempts" = 0, "LockedUntilUtc" = null, "LastLoginAtUtc" = timezone('utc', now())
      where "Username" = p_username;
    return query select true, v_display_name, v_warehouse_name, coalesce(v_super_user, false), coalesce(v_sales_user, false), coalesce(v_serial_admin, false), coalesce(v_delivery_team, false), coalesce(v_online_order_staff, false), coalesce(v_production_member, false), coalesce(v_payroll_officer, false), coalesce(v_store_manager, false), coalesce(v_conversations_staff, false), coalesce(v_must_change_password, false), 'OK'::text, coalesce(v_staff_roles, '{}'::text[]);
  else
    update public."StaffUsers"
      set "FailedAttempts" = "FailedAttempts" + 1,
          "LockedUntilUtc" = case when "FailedAttempts" + 1 >= 5 then now() + interval '15 minutes' else "LockedUntilUtc" end
      where "Username" = p_username;
    return query select false, null::text, null::text, false, false, false, false, false, false, false, false, false, false, 'Invalid username or password.'::text, '{}'::text[];
  end if;
end;
$$;

grant execute on function public.verify_login(text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_assign_online_order_maker: every assignment now Production Manager (or Super User) only.

drop function if exists public.admin_assign_online_order_maker(text, text, text, text, text);

create or replace function public.admin_assign_online_order_maker(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_role text,
  p_username text default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_username text := nullif(trim(coalesce(p_username, '')), '');
  v_role text := lower(trim(coalesce(p_role, '')));
  v_staff_role text;
  v_role_label text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if v_role not in ('tank', 'stand', 'dispatcher') then
    return query select false, 'p_role must be ''tank'', ''stand'' or ''dispatcher''.'::text;
    return;
  end if;

  if not exists (
    select 1 from public."StaffUsers"
    where "Username" = p_admin_username and "IsActive"
      and ("SuperUser" or 'ProductionManager' = any("StaffRoles"))
  ) then
    return query select false, 'Only a Production Manager can assign orders.'::text;
    return;
  end if;

  v_staff_role := case v_role when 'tank' then 'TankMaker' when 'stand' then 'StandMaker' else 'Dispatcher' end;
  v_role_label := case v_role when 'tank' then 'Tank Maker' when 'stand' then 'Stand Maker' else 'Dispatcher' end;

  if not exists (select 1 from public."OnlineOrders" where "OrderID" = p_order_id) then
    return query select false, 'Order not found.'::text;
    return;
  end if;

  if v_username is not null and not exists (
    select 1 from public."StaffUsers"
    where "Username" = v_username and "IsActive" and v_staff_role = any("StaffRoles")
  ) then
    return query select false, format('That user is not an active %s.', v_role_label)::text;
    return;
  end if;

  if v_role = 'tank' then
    update public."OnlineOrders" set "AssignedTankMaker" = v_username where "OrderID" = p_order_id;
  elsif v_role = 'stand' then
    update public."OnlineOrders" set "AssignedStandMaker" = v_username where "OrderID" = p_order_id;
  else
    update public."OnlineOrders" set "AssignedDispatcher" = v_username where "OrderID" = p_order_id;
  end if;

  return query select true, 'Assignment updated.'::text;
end;
$$;

grant execute on function public.admin_assign_online_order_maker(text, text, text, text, text) to anon;
