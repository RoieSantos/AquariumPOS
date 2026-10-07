-- Online Orders: Store Managers can To Ship their own branch's orders from the portal - per "can we
-- allow the store manager to-ship the order" / "allow the to ship to enable from Confirmed as well".
--
--   admin_store_manager_to_ship_online_order(...) - To Ship from Confirmed / Printed / Assigned, for a
--     Store Manager (or Super User) on an order at their OWN branch (StaffUsers.WarehouseName =
--     the order's Warehouses.Name). Same idea as admin_ship_online_order_from_stock: a Confirmed order
--     is treated as Printed inside the SAME transaction, then admin_update_online_order_status runs as
--     usual (serial claim, Pancake PATCH, customer message). If anything fails the whole call rolls
--     back and the order stays as it was.
--
--   Serials: picking them is optional here (a non-production store may have none on hand - the
--   desktop's To Ship lets those through too), but NEW serials are only allowed when the manager's
--   warehouse is a production warehouse (only production creates serials).
--
-- Run AFTER supabase_online_order_status_message_gma.sql. Safe to re-run.

drop function if exists public.admin_store_manager_to_ship_online_order(text, text, text, text, boolean, bigint[], jsonb);

create or replace function public.admin_store_manager_to_ship_online_order(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_new_status text,
  p_notify_customer boolean,
  p_serial_running_nos bigint[] default null,
  p_new_serials jsonb default null
)
returns table(new_status text, message_sent boolean, message_error text, created_serials jsonb,
              gma_psid text, gma_message text)
language plpgsql
security definer
set search_path = public, extensions
-- Same limits as admin_ship_online_order_from_stock: under the API gateway's ~60s, and a busy order
-- row gives a readable error after 10s instead of hanging.
set statement_timeout = '50000'
set lock_timeout = '10000'
as $$
declare
  v_status text;
  v_is_super boolean;
  v_staff_warehouse text;
  v_order_warehouse text;
  v_staff_is_production boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce(s."SuperUser", false), nullif(trim(s."WarehouseName"), '')
    into v_is_super, v_staff_warehouse
  from public."StaffUsers" s
  where s."Username" = p_admin_username and s."IsActive"
    and (coalesce(s."SuperUser", false) or coalesce(s."StoreManager", false));
  if not found then
    raise exception 'Only a Store Manager can To Ship an order from here.';
  end if;

  begin
    select lower(trim(coalesce(o."Status", ''))), w."Name"
      into v_status, v_order_warehouse
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    where o."OrderID" = p_order_id
    for update of o;
  exception when lock_not_available then
    raise exception 'Order % is busy (a sync or another update is still running on it). Wait a minute, refresh and try again.', p_order_id;
  end;
  if v_status is null then
    raise exception 'Order % not found.', p_order_id;
  end if;

  -- Own branch only (a Super User, or a manager with no warehouse set, isn't branch-scoped - same
  -- convention as the page's matchesWarehouseFilter).
  if not v_is_super and v_staff_warehouse is not null
     and coalesce(v_order_warehouse, '') <> v_staff_warehouse then
    raise exception 'Order % belongs to %, you can only To Ship orders for %.', p_order_id, coalesce(v_order_warehouse, 'another branch'), v_staff_warehouse;
  end if;

  if v_status not in ('confirmed', 'submitted', 'printed', 'assigned') then
    raise exception 'Order % is %, it can''t go To Ship from here.', p_order_id, v_status;
  end if;

  if p_new_serials is not null and jsonb_typeof(p_new_serials) = 'array' and jsonb_array_length(p_new_serials) > 0 then
    select coalesce(bool_or(coalesce(w."IsProductionWarehouse", false)), false) into v_staff_is_production
    from public."Warehouses" w
    where v_staff_warehouse is not null and w."Name" = v_staff_warehouse;
    if not v_is_super and not v_staff_is_production then
      raise exception 'Only a production warehouse can create new serials. Pick in-stock serials, or ship the units without one.';
    end if;
  end if;

  if v_status in ('confirmed', 'submitted') then
    update public."OnlineOrders" set "Status" = 'Printed' where "OrderID" = p_order_id;
  end if;

  return query
    select * from public.admin_update_online_order_status(
      p_admin_username, p_admin_password, p_order_id, p_new_status, p_notify_customer,
      p_serial_running_nos, p_new_serials);
end;
$$;

grant execute on function public.admin_store_manager_to_ship_online_order(text, text, text, text, boolean, bigint[], jsonb) to anon;
