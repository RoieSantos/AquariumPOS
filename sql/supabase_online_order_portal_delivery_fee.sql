-- Online Orders card: edit the Delivery Fee of a confirmed portal order - per "can we allow delivery fee to
-- edit even if the status is confirmed".
--
-- Portal orders only (OnlineOrders."Source" = 'Portal' - the AO-xxxxx orders made by Confirm Order,
-- supabase_bot_orders_portal_confirm.sql). A Pancake order's fee comes from Pancake's shipping_fee and the
-- next sync would overwrite it, so those are refused (set it in Pancake). Delivery orders only, and only
-- while the order is still open (not Shipped / Delivered / Completed / Cancelled / Returned).
--
-- Moves the money with it, the same way the Delivery page's manual fee does: Money to Collect and Balance
-- shift by (new fee - old fee). The source AutomatedOrders row ("DeliveryFee" / "EstimatedTotal",
-- supabase_gma_order_delivery_fee.sql) is kept in step, so the customer receipt / invoice / GMA order card
-- show the same fee. The Delivery page's own manual fee per stop still overrides it there.
--
-- New function only. Run AFTER supabase_gma_order_delivery_fee.sql. Safe to re-run.
-- Needs js/onlineOrders.js ?v=portalfee1.

drop function if exists public.admin_set_portal_order_delivery_fee(text, text, text, numeric);

create or replace function public.admin_set_portal_order_delivery_fee(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_delivery_fee numeric
)
returns table(delivery_fee numeric, money_to_collect numeric, balance numeric)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_order public."OnlineOrders"%rowtype;
  v_status text;
  v_old_fee numeric(18, 2);
  v_new_fee numeric(18, 2) := round(coalesce(p_delivery_fee, 0), 2);
  v_delta numeric(18, 2);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_new_fee < 0 then
    raise exception 'Delivery fee can''t be negative.';
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
    raise exception 'Order % is a Pancake order - set its delivery fee in Pancake instead.', v_order_id;
  end if;
  if not coalesce(v_order."ForDelivery", false) then
    raise exception 'Order % is a pickup order - it has no delivery fee.', v_order_id;
  end if;
  v_status := lower(trim(coalesce(v_order."Status", '')));
  if v_status in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning') then
    raise exception 'Order % is %, its delivery fee can no longer be changed.', v_order_id, v_order."Status";
  end if;

  v_old_fee := coalesce(v_order."DeliveryFee", 0);
  v_delta := v_new_fee - v_old_fee;

  update public."OnlineOrders"
  set "DeliveryFee" = nullif(v_new_fee, 0),
      "MoneyToCollect" = coalesce("MoneyToCollect", 0) + v_delta,
      "Balance" = coalesce("Balance", 0) + v_delta,
      "Last_Updated_At" = now()
  where "OrderID" = v_order_id;

  update public."AutomatedOrders"
  set "DeliveryFee" = v_new_fee,
      "EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta,
      "UpdatedAtUtc" = now()
  where "PancakeReceiptNo" = v_order_id and "PancakeSyncStatus" = 'Portal';

  return query
    select o."DeliveryFee", o."MoneyToCollect", o."Balance"
    from public."OnlineOrders" o where o."OrderID" = v_order_id;
end;
$$;

grant execute on function public.admin_set_portal_order_delivery_fee(text, text, text, numeric) to anon;

notify pgrst, 'reload schema';
