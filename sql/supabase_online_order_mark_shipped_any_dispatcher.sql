-- Mark Shipped for ANY Dispatcher - per "dispatcher's dont need to be assigned. any dispatcher can mark an order
-- shipped" / "its showing an error message that only the assigned dispatcher or production manager can
-- shipped this order".
--
-- That error is the OLD admin_mark_online_order_shipped (supabase_online_order_mark_shipped.sql). This file
-- holds only the current version (from supabase_online_order_dispatcher_on_ship.sql): any Dispatcher-role
-- user (or a Production Manager / Super User) can mark a To Ship order Shipped; a Dispatcher is recorded as
-- its Dispatcher, and every shipment is logged in OnlineOrderShipments.
--
-- Run on its own - safe to run any time after supabase_online_order_mark_shipped.sql. Unlike re-running
-- supabase_online_order_dispatcher_on_ship.sql, it does NOT touch the order list or maker rules.
-- New table (if missing) + one function - no OnlineOrders lock.

create table if not exists public."OnlineOrderShipments" (
  "OrderID" text primary key,
  "ShippedBy" text not null,
  "ShippedAtUtc" timestamptz not null default now(),
  "AsDispatcher" boolean not null
);

alter table public."OnlineOrderShipments" enable row level security;
revoke all on public."OnlineOrderShipments" from anon, authenticated;

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
  v_is_manager boolean;
  v_is_dispatcher boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select coalesce(s."SuperUser", false) or 'ProductionManager' = any(s."StaffRoles"),
         'Dispatcher' = any(s."StaffRoles")
    into v_is_manager, v_is_dispatcher
  from public."StaffUsers" s where s."Username" = p_admin_username and s."IsActive";

  if not coalesce(v_is_manager, false) and not coalesce(v_is_dispatcher, false) then
    return query select false, 'Only a Dispatcher or a Production Manager can mark orders shipped.'::text;
    return;
  end if;

  select "Status" into v_status from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    return query select false, 'Order not found.'::text;
    return;
  end if;

  if lower(trim(coalesce(v_status, ''))) not in ('to ship', 'packing', 'packed') then
    return query select false, format('Only a To Ship order can be marked shipped - this one is %s.', v_status)::text;
    return;
  end if;

  -- Raises (and rolls everything back) if Pancake rejects it.
  perform public._pancake_patch_online_order_status(p_order_id, jsonb_build_object('status', '2'));

  update public."OnlineOrders"
  set "Status" = 'Shipped',
      "AssignedDispatcher" = case when coalesce(v_is_dispatcher, false) then p_admin_username else "AssignedDispatcher" end
  where "OrderID" = p_order_id;

  insert into public."OnlineOrderShipments" ("OrderID", "ShippedBy", "AsDispatcher")
  values (p_order_id, p_admin_username, coalesce(v_is_dispatcher, false))
  on conflict ("OrderID") do update
    set "ShippedBy" = excluded."ShippedBy", "ShippedAtUtc" = now(), "AsDispatcher" = excluded."AsDispatcher";

  return query select true, 'Marked as shipped.'::text;
end;
$$;

grant execute on function public.admin_mark_online_order_shipped(text, text, text) to anon;
