-- Online Order Staff can't assign Tank / Stand Makers - per "for online order staff .. dont allow
-- them to assign to makers".
--
-- Assigning was already Production Manager / Super User only. This also refuses an account that is
-- Online Order Staff, even if it's ALSO a Production Manager (a Super User still can). The Online
-- Orders page hides the pick for them too (canAssignOrders in js/onlineOrders.js).
--
-- Re-creates admin_assign_online_order_maker exactly as in supabase_online_order_no_dispatcher_assign.sql
-- plus that one check. Run AFTER that file. Replaces one function - no table locks. Safe to re-run.
-- If supabase_online_order_no_dispatcher_assign.sql is ever re-run, run this one again afterwards.

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

  if v_role = 'dispatcher' then
    return query select false, 'Dispatchers aren''t assigned - any Dispatcher can mark a To Ship order Shipped, and is recorded then.'::text;
    return;
  end if;

  if v_role not in ('tank', 'stand') then
    return query select false, 'p_role must be ''tank'' or ''stand''.'::text;
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

  -- This file: Online Order Staff never assign, even with the Production Manager role.
  if exists (
    select 1 from public."StaffUsers"
    where "Username" = p_admin_username
      and coalesce("OnlineOrderStaff", false) and not coalesce("SuperUser", false)
  ) then
    return query select false, 'Online Order Staff can''t assign makers - ask the Production Manager.'::text;
    return;
  end if;

  v_staff_role := case v_role when 'tank' then 'TankMaker' else 'StandMaker' end;
  v_role_label := case v_role when 'tank' then 'Tank Maker' else 'Stand Maker' end;

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
  else
    update public."OnlineOrders" set "AssignedStandMaker" = v_username where "OrderID" = p_order_id;
  end if;

  return query select true, 'Assignment updated.'::text;
end;
$$;

grant execute on function public.admin_assign_online_order_maker(text, text, text, text, text) to anon;

notify pgrst, 'reload schema';
