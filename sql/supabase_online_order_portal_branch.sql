-- Online Orders card: change the warehouse (branch) of a confirmed portal order - per "can you also allow the
-- confirmed order edit the warehouse".
--
-- Portal orders only (OnlineOrders."Source" = 'Portal', the AO-xxxxx orders made by Confirm Order). A Pancake
-- order's warehouse comes from Pancake and the next sync would put it back, so those are refused. Status
-- Confirmed only - once it's Assigned / Printed / To Ship, makers, stock checks and serial picks are already
-- tied to the branch, so moving it then is refused.
--
-- Branch = Amaya or GMA, the same two AutomatedOrders."Location" values the order was created with; the
-- warehouse is matched by name exactly like admin_confirm_bot_order does. Updates OnlineOrders."LocationID"
-- and the source AutomatedOrders."Location" (receipt / invoice / GMA order card show the same branch).
--
-- New function only. Run AFTER supabase_bot_orders_portal_confirm.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=branch1.

drop function if exists public.admin_set_portal_order_branch(text, text, text, text);

create or replace function public.admin_set_portal_order_branch(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_location text
)
returns table(location_id text, warehouse_name text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_location text := trim(coalesce(p_location, ''));
  v_order public."OnlineOrders"%rowtype;
  v_warehouse_id text;
  v_warehouse_name text;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_location not in ('Amaya', 'GMA') then
    raise exception 'Branch must be Amaya or GMA.';
  end if;

  begin
    select * into v_order from public."OnlineOrders" where "OrderID" = v_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (another update is still running on it). Wait a minute, refresh and try again.', v_order_id;
  end;
  if not found then
    raise exception 'Order % not found.', v_order_id;
  end if;
  if coalesce(v_order."Source", '') <> 'Portal' then
    raise exception 'Order % is a Pancake order - change its warehouse in Pancake instead.', v_order_id;
  end if;
  if lower(trim(coalesce(v_order."Status", ''))) <> 'confirmed' then
    raise exception 'Order % is %, its warehouse can only be changed while it''s Confirmed.', v_order_id, v_order."Status";
  end if;

  -- Same branch -> warehouse match as admin_confirm_bot_order.
  select w."ID", w."Name" into v_warehouse_id, v_warehouse_name
  from public."Warehouses" w
  where w."Name" ilike '%' || v_location || '%'
  order by w."Name"
  limit 1;
  if v_warehouse_id is null then
    raise exception 'No Warehouses row matches branch "%".', v_location;
  end if;

  update public."OnlineOrders"
  set "LocationID" = v_warehouse_id,
      "Last_Updated_At" = now()
  where "OrderID" = v_order_id;

  update public."AutomatedOrders"
  set "Location" = v_location,
      "UpdatedAtUtc" = now()
  where "PancakeReceiptNo" = v_order_id and "PancakeSyncStatus" = 'Portal';

  return query select v_warehouse_id::text, v_warehouse_name::text;
end;
$$;

grant execute on function public.admin_set_portal_order_branch(text, text, text, text) to anon;

notify pgrst, 'reload schema';
