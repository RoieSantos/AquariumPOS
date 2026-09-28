-- "Mark Shipped" for To Ship orders - per "from to ship online orders.. how can we tagged it as
-- shipped should we add a new button to mark it as shipped".
--
-- The Production Manager / Super User's status-based button (docs/js/onlineOrders.js nextStepFor)
-- now reads "Mark Shipped" on a To Ship order. The order's own assigned Dispatcher can do it too, from
-- their My Assignments phone card - per "i want that dispatcher assigned to mark it as shipped". It sets Pancake to Shipped (status 2, same token as the
-- desktop's MapStatusForApi) and the portal to 'Shipped'. Same as the desktop's Shipped action
-- (ProductionDoneButton on a To Ship row): no customer message, no serial step (serials were claimed
-- at To Ship).
--
-- ALSO (security fix): the helper functions added for the Assigned / Production Done work were left
-- callable by the website's public (anon) key. The worst was _pancake_patch_online_order_status, which
-- PATCHes any order in Pancake with no login check. They're only meant to be called from inside the
-- login-checked functions, so they're revoked below - same convention as the _ile_* / _defect_*
-- helpers elsewhere.
--
-- Run AFTER supabase_online_order_assigned_status.sql (uses _pancake_patch_online_order_status). Only
-- replaces functions - no table locks.

drop function if exists public.admin_mark_online_order_shipped(text, text, text);

create or replace function public.admin_mark_online_order_shipped(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '45000'
as $$
declare
  v_status text;
  v_dispatcher text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select "Status", "AssignedDispatcher" into v_status, v_dispatcher from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    return query select false, 'Order not found.'::text;
    return;
  end if;

  -- Production Manager / Super User on any order, or the order's own assigned Dispatcher - per "i want
  -- that dispatcher assigned to mark it as shipped".
  if not exists (
    select 1 from public."StaffUsers"
    where "Username" = p_admin_username and "IsActive"
      and ("SuperUser" or 'ProductionManager' = any("StaffRoles")
           or ("Username" = v_dispatcher and 'Dispatcher' = any("StaffRoles")))
  ) then
    return query select false, 'Only this order''s Dispatcher or a Production Manager can mark it shipped.'::text;
    return;
  end if;

  if lower(trim(coalesce(v_status, ''))) not in ('to ship', 'packing', 'packed') then
    return query select false, format('Only a To Ship order can be marked shipped - this one is %s.', v_status)::text;
    return;
  end if;

  -- Raises (and rolls everything back) if Pancake rejects it.
  perform public._pancake_patch_online_order_status(p_order_id, jsonb_build_object('status', '2'));

  update public."OnlineOrders" set "Status" = 'Shipped' where "OrderID" = p_order_id;
  return query select true, 'Marked as shipped.'::text;
end;
$$;

grant execute on function public.admin_mark_online_order_shipped(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Security fix: internal helpers are not callable from the website directly.
revoke execute on function public._pancake_patch_online_order_status(text, jsonb) from public, anon, authenticated;
revoke execute on function public._online_order_assignment_complete(text) from public, anon, authenticated;
revoke execute on function public._online_order_production_roles(text) from public, anon, authenticated;
revoke execute on function public._is_order_maker_only(text) from public, anon, authenticated;

do $$
begin
  -- These exist only once the later files have been run - skip any that aren't there yet.
  if to_regprocedure('public._online_order_production_all_done(text)') is not null then
    revoke execute on function public._online_order_production_all_done(text) from public, anon, authenticated;
  end if;
  if to_regprocedure('public._online_order_my_parts_done(text, text)') is not null then
    revoke execute on function public._online_order_my_parts_done(text, text) from public, anon, authenticated;
  end if;
end;
$$;
