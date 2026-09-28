-- Ready to Ship creates (and the portal prints) serials when there's none in stock - per "is it
-- possible to move the printout of serials" / "at ready to ship".
--
-- Before: the portal's serial picker only offered existing In Stock serials; with none, Ready to Ship
-- was blocked ("finish this order on the desktop app"), because only the desktop POS could create
-- serials and print their labels. Now:
--   1. admin_update_online_order_status takes p_new_serials: units to create a NEW serial for. They are
--      numbered like the desktop (RS-<ItemCode>-<YY>-000001, one counter per item shared with
--      Production Orders' _production_next_serial_no), created SOLD to the order at the caller's
--      warehouse, and returned (created_serials) so the portal prints their labels straight away.
--      Guarded: only this order's serial-tracked lines, never more than a line still needs. Same
--      transaction as the Pancake update, so a failure creates nothing.
--   2. staff_get_online_order_serial_labels: every serial tied to an order, for reprinting labels.
-- The desktop POS pulls new Supabase serials down by UpdatedAtUtc, so its own numbering counts them.
--
-- Run AFTER supabase_online_order_to_ship_retry.sql. Replaces/adds functions - no table locks.

-- Next serial number (same as supabase_production_orders.sql - re-created here so this file works even
-- if Production Orders hasn't been set up).
create or replace function public._production_next_serial_no(p_item_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year text := to_char(now() at time zone 'Asia/Manila', 'YY');
  v_prefix_rs text := 'RS-' || p_item_code || '-' || v_year || '-';
  v_prefix text := p_item_code || '-' || v_year || '-';
  v_next int;
begin
  perform pg_advisory_xact_lock(hashtext('serialno|' || p_item_code));

  select coalesce(max(right(s."SerialNo", 6)::int), 0) + 1 into v_next
  from public."ItemSerialTracking" s
  where s."ItemCode" = p_item_code
    and (left(s."SerialNo", length(v_prefix_rs)) = v_prefix_rs or left(s."SerialNo", length(v_prefix)) = v_prefix)
    and right(s."SerialNo", 6) ~ '^[0-9]{6}$';

  return v_prefix_rs || lpad(v_next::text, 6, '0');
end;
$$;

revoke execute on function public._production_next_serial_no(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean, bigint[]);
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean, bigint[], jsonb);

create or replace function public.admin_update_online_order_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_new_status text,
  p_notify_customer boolean default false,
  p_serial_running_nos bigint[] default null,
  -- New serials to create for units with no In Stock serial (supabase_online_order_ship_new_serials.sql):
  -- [{"item_code": "...", "variation_id": "...", "description": "...", "quantity": 1}, ...]
  p_new_serials jsonb default null
)
returns table(new_status text, message_sent boolean, message_error text, created_serials jsonb)
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
  v_req record;
  v_needed int;
  v_have int;
  v_location text;
  v_serial text;
  v_created jsonb := '[]'::jsonb;
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

  -- Create new serials for units with no In Stock serial - per "is it possible to move the printout of
  -- serials" / "at ready to ship". Same as the desktop's To Ship (EnsureOrderSerialTrackingAsync ->
  -- CreateSoldSerialRecords): numbered RS-<ItemCode>-<YY>-<000001> (_production_next_serial_no, one
  -- counter per item), created already SOLD to this order at the caller's warehouse. Only for this
  -- order's serial-tracked lines and never more than a line still needs (picked serials count). Part of
  -- this call's transaction, so a failed Pancake update below rolls these back too.
  if p_new_serials is not null and jsonb_typeof(p_new_serials) = 'array' and jsonb_array_length(p_new_serials) > 0 then
    select coalesce(
      (select nullif(trim(s."WarehouseName"), '') from public."StaffUsers" s where s."Username" = p_admin_username),
      (select w."Name" from public."OnlineOrders" o join public."Warehouses" w on w."ID" = o."LocationID" where o."OrderID" = p_order_id)
    ) into v_location;

    for v_req in
      select * from jsonb_to_recordset(p_new_serials) as x(item_code text, variation_id text, description text, quantity int)
    loop
      select coalesce(sum(r.quantity_needed), 0) into v_needed
      from public.admin_get_online_order_serial_requirements(p_admin_username, p_admin_password, p_order_id) r
      where r.item_code = v_req.item_code and coalesce(r.variation_id, '') = coalesce(v_req.variation_id, '');

      select count(*) into v_have
      from public."ItemSerialTracking" s
      where s."SoldOnlineOrderId" = p_order_id and s."Status" = 'SOLD'
        and s."ItemCode" = v_req.item_code and coalesce(s."VariantCode", '') = coalesce(v_req.variation_id, '');

      if coalesce(v_req.quantity, 0) < 1 or v_have + v_req.quantity > v_needed then
        raise exception 'Can''t create % new serial(s) for % - this order needs % and % already have a serial.',
          coalesce(v_req.quantity, 0), v_req.item_code, v_needed, v_have;
      end if;

      for i in 1..v_req.quantity loop
        v_serial := public._production_next_serial_no(v_req.item_code);
        -- UpdatedAtUtc set so the desktop POS pulls it down (SyncItemSerialTrackingFromSupabaseAsync).
        insert into public."ItemSerialTracking"
          ("SerialNo", "ItemCode", "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedBy",
           "VariantCode", "SoldOnlineOrderId", "UpdatedAtUtc", "UpdatedBy")
        values
          (v_serial, v_req.item_code, left(coalesce(nullif(trim(v_req.description), ''), v_req.item_code), 255), v_location, 'SOLD', p_order_id, p_admin_username,
           nullif(trim(coalesce(v_req.variation_id, '')), ''), p_order_id, now(), p_admin_username);
        v_created := v_created || jsonb_build_array(jsonb_build_object(
          'serial_no', v_serial, 'item_code', v_req.item_code,
          'description', coalesce(nullif(trim(v_req.description), ''), v_req.item_code)));
      end loop;
    end loop;
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

  return query select p_new_status, v_message_sent, v_message_error, v_created;
end;
$$;

grant execute on function public.admin_update_online_order_status(text, text, text, text, boolean, bigint[], jsonb) to anon;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_get_online_order_serial_labels(text, text, text);

create or replace function public.staff_get_online_order_serial_labels(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(serial_no text, item_code text, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s."SerialNo"::text, s."ItemCode"::text, coalesce(nullif(trim(s."ItemDescription"), ''), s."ItemCode")::text
    from public."ItemSerialTracking" s
    where s."SoldOnlineOrderId" = p_order_id
      and coalesce(s."Status", '') <> 'REVERSED'
    order by s."ItemCode", s."SerialNo";
end;
$$;

grant execute on function public.staff_get_online_order_serial_labels(text, text, text) to anon;

notify pgrst, 'reload schema';
