-- Retries for Ready to Ship / To Ship - per "error on ready to ship can we put retries here too?"
-- ("Could not update status: OpenSSL SSL_read: SSL_ERROR_SYSCALL, errno 0").
--
-- admin_update_online_order_status (Ready to Ship on the portal, To Ship) had its own Pancake PATCH that
-- only tried twice back to back. It now uses the shared _pancake_patch_online_order_status, which tries
-- up to 3 times with pauses (supabase_pancake_patch_retry.sql) and keeps bank_payments the same way.
-- Everything else is unchanged (copied from supabase_online_order_assigned_status.sql).
--
-- Run AFTER supabase_pancake_patch_retry.sql. Replaces one function - no table locks.

create or replace function public.admin_update_online_order_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_new_status text,
  p_notify_customer boolean default false,
  p_serial_running_nos bigint[] default null
)
returns table(new_status text, message_sent boolean, message_error text)
language plpgsql
security definer
set search_path = public, extensions
-- Overrides whatever statement_timeout the authenticator role happens to have (previously seen
-- hitting Postgres's default ~8s and killing this mid-flight - "canceling statement due to
-- statement timeout" - since this chains a GET + PATCH + PATCH, each with its own retry). Set
-- directly on the function so it's guaranteed regardless of role/session config.
set statement_timeout = '60000'
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_order_url text;
  v_current_status text;
  v_api_token text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_patch_response extensions.http_response;
  v_message_sent boolean := false;
  v_message_error text;
  v_requested_serial_count int;
  v_claimed_serial_count int;
  v_patch_attempt int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "Status" into v_current_status from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    raise exception 'Order % not found.', p_order_id;
  end if;

  if lower(trim(coalesce(v_current_status, ''))) = 'new' then
    raise exception 'Cannot change status for orders with status ''new'' - please ask the online sales team to confirm the order first.';
  end if;

  if lower(trim(p_new_status)) <> 'to ship' then
    raise exception 'You can only change status to ''To Ship'' from here.';
  end if;

  -- Mirrors OnlineOrdersForm.cs's IsPrintedStatusForRow gate on MarkRowAsToShipAsync - the desktop
  -- app already refuses to mark an order 'To Ship' unless it's currently 'Printed' ("Update not
  -- allowed status is not \"printed\""), so this portal RPC needs the same guard, not just the
  -- 'new' check above - otherwise a Confirmed-but-not-yet-printed order could be jumped straight
  -- to To Ship from here even though the desktop app would block it.
  -- 'Assigned' (supabase_online_order_assigned_status.sql) is a Printed order whose makers are set,
  -- so it can go To Ship too.
  if lower(trim(coalesce(v_current_status, ''))) not in ('printed', 'assigned') then
    raise exception 'Cannot mark as To Ship - this order''s status is not ''Printed'' yet. Print the order first.';
  end if;

  -- Mirrors OnlineOrdersForm.cs's EnsureOrderSerialTrackingAsync, which the desktop's own To Ship
  -- action runs before changing status: a production warehouse can't ship a serial-tracked item
  -- (e.g. a custom aquarium) without a physical unit's serial tied to the order. The portal's
  -- picker (docs/js/onlineOrders.js) only ever offers EXISTING IN_STOCK serials, never generates
  -- new ones (per direct instruction - unlike the desktop, which can auto-create + print labels),
  -- so p_serial_running_nos is only ever populated when every required line was fully covered by
  -- available stock; the caller blocks Ship client-side otherwise and tells staff to finish on the
  -- desktop app instead. Claiming BEFORE the Pancake calls below means if the Pancake PATCH fails
  -- later and this function raises, Postgres rolls back this UPDATE too (same implicit-transaction
  -- semantics as everything else in a single SECURITY DEFINER call) - so a failed attempt never
  -- leaves serials claimed against an order that's still sitting at 'Printed' in Pancake.
  if p_serial_running_nos is not null and array_length(p_serial_running_nos, 1) > 0 then
    v_requested_serial_count := array_length(p_serial_running_nos, 1);

    with claimed as (
      update public."ItemSerialTracking"
        set "Status" = 'SOLD',
            "SoldOnlineOrderId" = p_order_id,
            "UpdatedAtUtc" = now()
        where "RunningSerialNo" = any(p_serial_running_nos) and "Status" = 'IN_STOCK'
        returning "RunningSerialNo"
    )
    select count(*) into v_claimed_serial_count from claimed;

    if v_claimed_serial_count < v_requested_serial_count then
      raise exception 'Only % of % selected serial(s) were still available - someone may have just claimed one. Refresh and try again.', v_claimed_serial_count, v_requested_serial_count;
    end if;
  end if;

  v_api_token := '8'; -- MapStatusForApi's token for 'To Ship'

  -- Pancake PATCH (bank_payments snapshot/restore + up to 3 tries with pauses on a dropped connection
  -- such as "OpenSSL SSL_read: SSL_ERROR_SYSCALL") - shared helper, supabase_pancake_patch_retry.sql.
  -- Raises if Pancake can't be reached, which rolls back the serial claim above too.
  perform public._pancake_patch_online_order_status(p_order_id, jsonb_build_object('status', v_api_token));

  -- Reflects immediately in the portal without waiting for the next cron sync pass - harmless even
  -- though OnlineOrders is normally a Pancake -> Supabase mirror, since this is exactly the value
  -- Pancake now actually has.
  update public."OnlineOrders" set "Status" = p_new_status where "OrderID" = p_order_id;

  if p_notify_customer then
    begin
      perform public._send_online_order_status_message(p_order_id, p_new_status);
      v_message_sent := true;
    exception when others then
      v_message_error := sqlerrm;
    end;
  end if;

  return query select p_new_status, v_message_sent, v_message_error;
end;
$$;

grant execute on function public.admin_update_online_order_status(text, text, text, text, boolean, bigint[]) to anon;
