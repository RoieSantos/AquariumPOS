-- Adds an "Assigned Dispatcher" to every online order, per "can we assign a dispatcher too?" -
-- picked from staff holding the Dispatcher Staff Role (User Setup, supabase_staff_users_staff_roles.sql),
-- the same way Tank/Stand Maker pick from TankMaker/StandMaker (supabase_online_order_maker_by_role.sql).
-- Unlike the makers, a dispatcher applies to any order (not only custom aquarium/stand lines), and
-- it does NOT feed the derived "Assigned" status - that still means "every needed maker is set".
--
-- - OnlineOrders."AssignedDispatcher": new column. Portal-only bookkeeping, no Pancake call.
-- - staff_list_order_makers: now also returns Dispatcher-role staff (roster for all 3 dropdowns).
-- - admin_assign_online_order_maker: p_role also accepts 'dispatcher'.
-- - staff_get_online_order_assignments: returns the dispatcher (+ display name) for a batch of
--   order ids. The portal calls it for the orders on screen, so admin_list_online_orders' long
--   return signature doesn't have to be redefined just for one more column.
--
-- Run this AFTER supabase_online_order_maker_by_role.sql.

alter table public."OnlineOrders"
    add column if not exists "AssignedDispatcher" text;

-- ---------------------------------------------------------------------------

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
    where "IsActive" and "StaffRoles" && array['TankMaker', 'StandMaker', 'Dispatcher']::text[]
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

-- ---------------------------------------------------------------------------

drop function if exists public.staff_get_online_order_assignments(text, text, text[]);

create or replace function public.staff_get_online_order_assignments(p_admin_username text, p_admin_password text, p_order_ids text[])
returns table(order_id text, assigned_dispatcher text, assigned_dispatcher_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."OrderID"::text, o."AssignedDispatcher"::text,
           coalesce(nullif(trim(s."DisplayName"), ''), o."AssignedDispatcher")::text
    from public."OnlineOrders" o
    left join public."StaffUsers" s on s."Username" = o."AssignedDispatcher"
    where o."OrderID" = any(coalesce(p_order_ids, '{}'))
      and o."AssignedDispatcher" is not null;
end;
$$;

grant execute on function public.staff_get_online_order_assignments(text, text, text[]) to anon;
