-- Status messages (To Ship "ready for pickup" + its photo) for GMA Page orders too - per "since I enable
-- [Human Agent] can we use that for our status updating to the customer? ... follow same routine ... check
-- on the tag GMA Conversations then send it over to GMA page's customer".
--
-- Same approach as supabase_online_order_assigned_message_gma.sql: a GMA-originated order ("GMA Page"
-- badge - AutomatedOrders.GmaPsid) has no Pancake conversation, so _send_online_order_status_message
-- silently skipped it and the To Ship photo failed with "missing Page_ID/Conversation_ID". The GMA Page's
-- page token only exists in Edge Function secrets, so for a GMA order admin_update_online_order_status
-- now returns the psid + the exact same message text instead of sending, and js/onlineOrders.js sends it
-- through chatbot-staff-reply (normal send inside 24h, HUMAN_AGENT-tagged after that once Meta approves
-- it - up to 7 days). The photo goes the same way, logged with admin_record_online_order_status_photo.
--
-- Pancake orders: unchanged - same templates (copied verbatim from supabase_online_order_portal_status_
-- update.sql), same send.
--
-- Run AFTER supabase_online_order_ship_new_serials.sql and supabase_online_order_assigned_message_gma.sql;
-- if either is re-run, run this one again after it. Functions only - no table locks.

-- ---------------------------------------------------------------------------
-- 1. GMA detection - same join as admin_get_online_order_messaging_route (supabase_online_order_send_message.sql).
create or replace function public._online_order_gma_psid(p_order_id text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select ao."GmaPsid"
  from public."AutomatedOrders" ao
  where ao."PancakeReceiptNo" = p_order_id
    and ao."GmaPsid" is not null
  limit 1;
$$;

revoke execute on function public._online_order_gma_psid(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Status message text on its own, so the Pancake and GMA routes send the exact same words.
create or replace function public._online_order_status_message_text(p_order_id text, p_new_status text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."OnlineOrders"%rowtype;
  v_template text;
  v_items_text text;
  v_payment_text text := '';
  v_message text;
begin
  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;

  if lower(trim(p_new_status)) = 'pending transfer' then
    v_template := $msg$🎉 Hi {Customer Name}! Your order {Order ID} is now finished and will be transferred to RSPETSTOP {location} location on our next delivery schedule.
We'll notify you once it's ready for pickup at the branch.
{Payment}

🧾 Heres what youll be receiving:

 {Items}


Swing by anytime during our store hours—your fish joy is just one finstep away! 🐠🦈
📍 Amaya: Amaya Dos Antero Soriano Highway Tanza Cavite or just Pin : RSPetStop Amaya
📍 GMA: RSPetStop GMA Branch
🕒 Hours: 8:00 am to 8:00 pm monday to sunday
You may call +63 997 189 1662 (GMA Branch) for any questions or assistance. We look forward to seeing you soon! 🐟❤️
We can also help you book a lalamove delivery partner
📦 Kindly send the following details

• Full Name:
• Contact Number:
• Complete Address:
• Pin Location (Google Maps link or screenshot):
💬 Once received, well confirm your order and send the final details right away. Thank you
Thank you for choosing RSPetStop—We appreciate you always! and see you soon ❤️$msg$;
  else
    v_template := $msg$🎉 Hi {Customer Name}! Your order {Order ID} is now ready for pickup at RSPetStop.
{Payment}

🧾 Heres what youll be receiving:

 {Items}


Swing by anytime during our store hours—your fish joy is just one finstep away! 🐠🦈
📍 Location: Amaya Dos Antero Soriano Highway Tanza Cavite or just Pin : RSPetStop Amaya
🕒 Hours: 8:00 am to 8:00 pm monday to sunday
For GMA Location, You can pickup your order on the next Delivery schedule. You can coordinate with us with this. Happy fish keeping.
You may call +63 997 189 1662 (GMA Branch) for any questions or assistance. We look forward to seeing you soon! 🐟❤️
We can also help you book a lalamove delivery partner
📦 Kindly send the following details

• Full Name:
• Contact Number:
• Complete Address:
• Pin Location (Google Maps link or screenshot):
💬 Once received, well confirm your order and send the final details right away. Thank you
Thank you for choosing RSPetStop—We appreciate you always! and see you soon ❤️$msg$;
  end if;

  select string_agg(
    case when nullif(trim(coalesce(l."Note", '')), '') is null
      then '✅ ' || trim(to_char(coalesce(l."Quantity", 1), 'FM999999990.##')) || ' x ' || coalesce(nullif(trim(l."Description"), ''), l."ItemCode")
      else '✅ ' || trim(to_char(coalesce(l."Quantity", 1), 'FM999999990.##')) || ' x ' || coalesce(nullif(trim(l."Description"), ''), l."ItemCode") || ' 🧾 Note : ' || l."Note"
    end,
    chr(10) order by l."LineID"
  ) into v_items_text
  from public."OnlineOrderLines" l
  where l."OrderID" = p_order_id;

  if coalesce(v_order."Balance", 0) > 0 then
    v_payment_text := 'Please settle remaining balance to continue on the delivery.' || chr(10) || chr(10) ||
      'Balance : ' || to_char(v_order."Balance", 'FM999,999,990.00');
  end if;

  v_message := v_template;
  v_message := replace(v_message, '{Customer Name}', coalesce(v_order."CustomerName", ''));
  v_message := replace(v_message, '{Order ID}', p_order_id);
  v_message := replace(v_message, '{location}', coalesce(v_order."LocationID", ''));
  v_message := replace(v_message, '{Payment}', v_payment_text);
  v_message := replace(v_message, '{Items}', coalesce(v_items_text, ''));

  return v_message;
end;
$$;

revoke execute on function public._online_order_status_message_text(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Pancake send - unchanged behaviour, now using the shared text above.
create or replace function public._send_online_order_status_message(p_order_id text, p_new_status text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."OnlineOrders"%rowtype;
  v_response extensions.http_response;
begin
  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found or v_order."Page_ID" is null or v_order."Conversation_ID" is null
     or trim(v_order."Page_ID") = '' or trim(v_order."Conversation_ID") = '' then
    return; -- same "missing Page_ID/Conversation_ID, cannot send" guard as the desktop app
  end if;

  select * into v_response from extensions.http((
    'POST',
    'https://pages.fm/api/public_api/v1/pages/' || v_order."Page_ID" || '/conversations/' || v_order."Conversation_ID"
      || '/messages?page_access_token=' || public._pancake_public_api_key(),
    array[
      extensions.http_header('Accept', 'application/json'),
      extensions.http_header('Expect', '')
    ],
    'application/json',
    -- json_build_object (not jsonb_build_object) - see admin_send_online_order_status_photo's matching
    -- comment (supabase_online_order_portal_status_update.sql) for why the key order matters here.
    json_build_object('action', 'reply_inbox', 'message', public._online_order_status_message_text(p_order_id, p_new_status))::text
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake messaging API returned HTTP %.', v_response.status;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Same as supabase_online_order_ship_new_serials.sql's version, plus gma_psid/gma_message: when
--    notifying a GMA order's customer, nothing is sent here - the client sends it via chatbot-staff-reply.
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
returns table(new_status text, message_sent boolean, message_error text, created_serials jsonb,
              gma_psid text, gma_message text)
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
  v_gma_psid text;
  v_gma_message text;
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
    v_gma_psid := public._online_order_gma_psid(p_order_id);
    if v_gma_psid is not null then
      -- GMA Page order: the client sends it via chatbot-staff-reply (supabase_online_order_status_message_gma.sql).
      v_gma_message := public._online_order_status_message_text(p_order_id, p_new_status);
    else
      begin
        perform public._send_online_order_status_message(p_order_id, p_new_status);
        v_message_sent := true;
      exception when others then
        v_message_error := sqlerrm;
      end;
    end if;
  end if;

  return query select p_new_status, v_message_sent, v_message_error, v_created, v_gma_psid, v_gma_message;
end;
$$;

grant execute on function public.admin_update_online_order_status(text, text, text, text, boolean, bigint[], jsonb) to anon;

-- ---------------------------------------------------------------------------
-- 5. Logs a photo the client sent to a GMA customer, into the same OnlineOrderStatusPhotos history
--    admin_send_online_order_status_photo writes for Pancake orders.
create or replace function public.admin_record_online_order_status_photo(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_photo_url text,
  p_photo_storage_path text,
  p_sent boolean,
  p_error text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  insert into public."OnlineOrderStatusPhotos" ("OrderID", "Status", "StoragePath", "PublicUrl", "SentToCustomer", "SendError", "UploadedBy")
  select p_order_id, o."Status", coalesce(p_photo_storage_path, ''), p_photo_url, coalesce(p_sent, false), p_error, p_admin_username
  from public."OnlineOrders" o
  where o."OrderID" = p_order_id;
end;
$$;

grant execute on function public.admin_record_online_order_status_photo(text, text, text, text, text, boolean, text) to anon;
