-- Delivery Fee on a pickup order - per "how can we remove the delivery fee of the online order?"
-- (AO-00251: For Delivery = No, but a 1677.00 fee, status To Ship - the card showed the fee as plain
-- text and the server refused "is a pickup order - it has no delivery fee", so it could never be removed).
--
-- admin_set_portal_order_delivery_fee re-created (latest: supabase_order_card_delivery_fee_walkin_advance.sql
-- step 2) - a non-walk-in order that isn't For Delivery and has no stops is now allowed when it already
-- HAS a fee, so it can be lowered / cleared to 0. Pickup orders with no fee are still refused. Everything
-- else unchanged.
--
-- Run AFTER supabase_order_card_delivery_fee_walkin_advance.sql. Do NOT re-run that file after this one
-- (it would put back the pickup refusal) - if you must, re-run this file after it. Safe to re-run.
-- Needs js/onlineOrders.js ?v=pickupfee1.

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
  v_walkin boolean;
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

  v_walkin := coalesce(v_order."ReceivedAtShop", false);
  v_status := lower(trim(coalesce(v_order."Status", '')));

  if v_walkin then
    -- Walk-ins are Shipped in Pancake from the start, so their open/closed is the portal's own.
    if v_status in ('cancelled', 'canceled', 'returned', 'returning') then
      raise exception 'Order % is %, its delivery fee can no longer be changed.', v_order_id, v_order."Status";
    end if;
    if v_order."PickedUpAtUtc" is not null then
      raise exception 'Order % was already picked up, its delivery fee can no longer be changed.', v_order_id;
    end if;
    if v_order."DeliveredAtUtc" is not null then
      raise exception 'Order % was already delivered, its delivery fee can no longer be changed.', v_order_id;
    end if;
  else
    if not coalesce(v_order."ForDelivery", false)
       and not exists (select 1 from public."DeliveryStops" s where s."OrderID" = v_order_id)
       and coalesce(v_order."DeliveryFee", 0) <= 0 then -- a pickup order that has a fee can still clear it
      raise exception 'Order % is a pickup order - it has no delivery fee.', v_order_id;
    end if;
    if v_status in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning') then
      raise exception 'Order % is %, its delivery fee can no longer be changed.', v_order_id, v_order."Status";
    end if;
  end if;

  v_old_fee := coalesce(v_order."DeliveryFee", 0);
  v_delta := v_new_fee - v_old_fee;

  update public."OnlineOrders"
  set "DeliveryFee" = nullif(v_new_fee, 0),
      "PortalDeliveryFee" = v_new_fee, -- kept over the next Pancake sync
      "MoneyToCollect" = coalesce("MoneyToCollect", 0) + v_delta,
      "Balance" = coalesce("Balance", 0) + v_delta,
      "Last_Updated_At" = now()
  where "OrderID" = v_order_id;

  update public."AutomatedOrders"
  set "DeliveryFee" = v_new_fee,
      "EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta,
      "UpdatedAtUtc" = now()
  where "PancakeReceiptNo" = v_order_id and "PancakeSyncStatus" = 'Portal';

  -- The calendar follows the order's fee from now on.
  update public."DeliveryStops"
  set "ManualDeliveryFee" = null
  where "OrderID" = v_order_id and "ManualDeliveryFee" is not null;

  return query
    select o."DeliveryFee", o."MoneyToCollect", o."Balance"
    from public."OnlineOrders" o where o."OrderID" = v_order_id;
end;
$$;

grant execute on function public.admin_set_portal_order_delivery_fee(text, text, text, numeric) to anon;

-- Verification - one result.
select 'pickup with fee allowed' as check_name,
       (pg_get_functiondef('public.admin_set_portal_order_delivery_fee(text, text, text, numeric)'::regprocedure)
         like '%v_order."DeliveryFee", 0) <= 0%')::text as ok;
