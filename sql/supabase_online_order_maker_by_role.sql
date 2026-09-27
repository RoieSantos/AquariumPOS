-- Online Orders' Tank Maker / Stand Maker dropdowns now pick from the new Staff Roles (User Setup,
-- supabase_staff_users_staff_roles.sql) instead of the generic "Production Member" flag, per
-- "can I assign the specific employee? base on the role". Tank Maker dropdown = staff with the
-- TankMaker role, Stand Maker dropdown = staff with the StandMaker role.
--
-- - staff_list_order_makers: new roster RPC returning each active maker with their roles, so the
--   portal can filter the two dropdowns client-side from one call. staff_list_production_members
--   is left in place (unused by the portal after this) rather than dropped.
-- - admin_assign_online_order_maker: same signature/behaviour, but validates the matching role
--   (TankMaker for 'tank', StandMaker for 'stand') instead of "ProductionMember". Clearing an
--   assignment (p_username null) still always works. Existing assignments are untouched.
--
-- Run this AFTER supabase_staff_users_staff_roles.sql and supabase_online_order_production_assignment.sql.

drop function if exists public.staff_list_order_makers(text, text);

create or replace function public.staff_list_order_makers(p_admin_username text, p_admin_password text)
returns table(username text, display_name text, staff_roles text[])
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "Username"::text, coalesce(nullif(trim("DisplayName"), ''), "Username")::text, "StaffRoles"
    from public."StaffUsers"
    where "IsActive" and "StaffRoles" && array['TankMaker', 'StandMaker']::text[]
    order by coalesce(nullif(trim("DisplayName"), ''), "Username");
end;
$$;

grant execute on function public.staff_list_order_makers(text, text) to anon;

-- ---------------------------------------------------------------------------

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
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if v_role not in ('tank', 'stand') then
    return query select false, 'p_role must be ''tank'' or ''stand''.'::text;
    return;
  end if;

  v_staff_role := case v_role when 'tank' then 'TankMaker' else 'StandMaker' end;

  if not exists (select 1 from public."OnlineOrders" where "OrderID" = p_order_id) then
    return query select false, 'Order not found.'::text;
    return;
  end if;

  if v_username is not null and not exists (
    select 1 from public."StaffUsers"
    where "Username" = v_username and "IsActive" and v_staff_role = any("StaffRoles")
  ) then
    return query select false, format('That user is not an active %s.', case v_role when 'tank' then 'Tank Maker' else 'Stand Maker' end)::text;
    return;
  end if;

  if v_role = 'tank' then
    update public."OnlineOrders" set "AssignedTankMaker" = v_username where "OrderID" = p_order_id;
  else
    update public."OnlineOrders" set "AssignedStandMaker" = v_username where "OrderID" = p_order_id;
  end if;

  return query select true, 'Assignment updated.'::text;
end;
$$;

grant execute on function public.admin_assign_online_order_maker(text, text, text, text, text) to anon;
