-- Restricts removing a Delivery stop to super users only. Every other Delivery RPC stays
-- is_staff_authorized (open to all active staff) - this is the one exception.
-- Per "if the user is not super user dont allow removing the stops in the delivery".
-- delivery.js also hides the Remove button client-side for non-super users, but this is the
-- actual enforcement (the RPC re-checks regardless of what the UI shows).

create or replace function public.admin_delete_delivery_stop(p_admin_username text, p_admin_password text, p_stop_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_id text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."DeliveryStops" where "StopID" = p_stop_id returning "OrderID" into v_order_id;

  if v_order_id is not null and not exists (select 1 from public."DeliveryStops" where "OrderID" = v_order_id) then
    update public."OnlineOrders" set "ForDelivery" = false where "OrderID" = v_order_id;
  end if;
end;
$$;
