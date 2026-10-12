-- Online Order Staff can Ready to Ship a Confirmed stock order - per "online order staff can do:
-- Confirmed orders they can Ready-to Ship but the serial step need still. If an order is custom they
-- cannot Ready-to ship".
--
-- admin_ship_online_order_from_stock was Production Manager / Super User only. This also allows an
-- account with Online Order Staff ticked. Everything else is unchanged:
--   * the in-stock serial(s) must still be picked for every serial-tracked unit - but an order with NO
--     serial-tracked items (accessories / normal items) can now ship with none, per "can we allow the
--     online staff orders to to-ship products no need serials?" (checked server-side via
--     admin_get_online_order_serial_requirements; applies to Production Managers too),
--   * custom orders (Tank / Stand Maker work) are still refused until every part is Production Done -
--     admin_update_online_order_status' gate (supabase_online_order_to_ship_production_gate.sql), which
--     this calls at the end,
--   * Pancake status update + optional customer message, same as before.
--
-- Re-creates admin_ship_online_order_from_stock exactly as in supabase_online_order_stock_ship.sql plus
-- the Online Order Staff check. Run AFTER that file. Replaces one function - no table locks. Safe to
-- re-run. If supabase_online_order_stock_ship.sql is ever re-run, run this one again afterwards.

drop function if exists public.admin_ship_online_order_from_stock(text, text, text, text, boolean, bigint[], jsonb);

create or replace function public.admin_ship_online_order_from_stock(
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
-- Kept UNDER the API gateway's ~60s limit: past it the gateway drops the connection with no CORS
-- headers and the browser only says "TypeError: Failed to fetch" (per "still erroring on the to-ship").
-- Waiting on the order's row lock (a background Pancake sync or an earlier attempt still running) now
-- gives up after 10s with a readable error instead of hanging until the gateway cuts it.
set statement_timeout = '50000'
set lock_timeout = '10000'
as $$
declare
  v_status text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not exists (
    select 1 from public."StaffUsers" s
    where s."Username" = p_admin_username and s."IsActive"
      and (s."SuperUser" or 'ProductionManager' = any(coalesce(s."StaffRoles", '{}'))
           or coalesce(s."OnlineOrderStaff", false))   -- this file
  ) then
    raise exception 'Only a Production Manager or Online Order Staff can ship an order from stock.';
  end if;

  begin
    select lower(trim(coalesce("Status", ''))) into v_status from public."OnlineOrders" where "OrderID" = p_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (a sync or another update is still running on it). Wait a minute, refresh and try again.', p_order_id;
  end;
  if v_status is null then
    raise exception 'Order % not found.', p_order_id;
  end if;
  if v_status not in ('confirmed', 'submitted', 'printed', 'assigned') then
    raise exception 'Order % is %, it can''t go To Ship from here.', p_order_id, v_status;
  end if;
  -- This file: no serials picked is fine only when the order has NO serial-tracked units at all
  -- (accessories / normal items) - checked here, not trusted from the page.
  if coalesce(array_length(p_serial_running_nos, 1), 0) = 0
     and exists (
       select 1 from public.admin_get_online_order_serial_requirements(p_admin_username, p_admin_password, p_order_id) r
       where coalesce(r.quantity_needed, 0) > 0
     ) then
    raise exception 'Pick the in-stock serial(s) for this order first.';
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

grant execute on function public.admin_ship_online_order_from_stock(text, text, text, text, boolean, bigint[], jsonb) to anon;

notify pgrst, 'reload schema';
