-- Lets staff change an Online Order's status directly from the Web Portal (docs/online-orders.html)
-- and optionally notify the customer - per direct request to bring the desktop app's "change
-- status to To Ship -> ask to notify the customer" experience to the portal too, with status
-- changes actually pushed to Pancake (not just read from it, which is all the portal did before).
--
-- Faithfully mirrors OnlinefunctionsEvents/OnlineOrdersForm.cs's existing desktop flow (verified
-- against the real C# before writing this):
--   - Same Pancake endpoint/method: PATCH https://pos.pages.fm/api/v1/shops/1328301944/
--     orders/{orderId}?api_key=...&page_size=1000 (IntegrationEvents.cs's BuildOnlineOrderUpdate
--     Endpoint/SendOnlineOrderUpdatePayload) - unlike the C# side, no PUT-on-404 fallback here,
--     matching how every other Pancake write in this codebase (_push_automated_order_to_pancake
--     etc.) just PATCHes/POSTs once.
--   - Same bank_payments snapshot-before/restore-after workaround (GetBankPaymentsSnapshotAsync/
--     RestoreBankPaymentsAsync) - Pancake's PATCH silently wipes an order's bank_payments unless
--     it's re-sent, so this GETs the order first, extracts bank_payments, PATCHes status, then
--     PATCHes bank_payments back. Best-effort on the restore, same as the C# (never blocks the
--     status change itself on the restore's outcome).
--   - Same status -> Pancake token mapping (MapStatusForApi).
--   - Same message template (GlobalSettings.PickupReadyMessage, copied verbatim including its
--     placeholders) - notifying only ever makes sense for To Ship, gated by the client's own
--     "update the customer?" confirm before passing p_notify_customer = true.
--
-- Per direct follow-up request, staff can ONLY manually set an order to 'To Ship' from here - no
-- free-form status editor. Every other status (Shipped, Pending Transfer, In-Transit, Received,
-- Production Done) only ever changes via the background Pancake sync, same as before this feature
-- existed. This is enforced here too (not just hidden in the UI), since this function is reachable
-- directly by anyone with valid staff credentials, not only through the portal's button.

drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean);
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean, text);
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean, text, text);
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean, text, text, bigint[]);

create or replace function public.admin_update_online_order_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_new_status text,
  p_notify_customer boolean default false,
  p_photo_url text default null,
  p_photo_storage_path text default null,
  p_serial_running_nos bigint[] default null
)
returns table(new_status text, message_sent boolean, message_error text, photo_sent boolean, photo_error text)
language plpgsql
security definer
set search_path = public, extensions
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
  v_photo_sent boolean;
  v_photo_error text;
  v_requested_serial_count int;
  v_claimed_serial_count int;
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
  if lower(trim(coalesce(v_current_status, ''))) <> 'printed' then
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

  v_order_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || p_order_id || '?api_key=' || v_api_key || '&page_size=1000';

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  -- Snapshot bank_payments before the status PATCH - see file header for why.
  begin
    select * into v_get_response from extensions.http_get(v_order_url);
    if v_get_response.status >= 200 and v_get_response.status < 300 then
      v_get_body := v_get_response.content::jsonb;
      v_order_obj := case
        when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
        when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
        else v_get_body
      end;
      if jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then
        v_bank_payments := v_order_obj -> 'bank_payments';
      end if;
    end if;
  exception when others then
    v_bank_payments := null; -- best-effort, same as the C# GetBankPaymentsSnapshotAsync
  end;

  -- Header set matches the one proven working elsewhere in this codebase for Pancake writes (see
  -- _push_automated_order_to_pancake's comment) - 'Expect: ' suppresses libcurl's automatic
  -- "Expect: 100-continue" header, which Pancake's side has been observed to mishandle.
  select * into v_patch_response from extensions.http((
    'PATCH',
    v_order_url,
    array[
      extensions.http_header('Accept', 'application/json'),
      extensions.http_header('Expect', '')
    ],
    'application/json',
    jsonb_build_object('status', v_api_token)::text
  )::extensions.http_request);

  if v_patch_response.status < 200 or v_patch_response.status >= 300 then
    raise exception 'Pancake rejected the status update (HTTP %).', v_patch_response.status;
  end if;

  -- Restore bank_payments after a successful status PATCH - best-effort, never blocks the status
  -- change itself, matching RestoreBankPaymentsAsync's own contract.
  if v_bank_payments is not null then
    begin
      perform extensions.http((
        'PATCH',
        v_order_url,
        array[
          extensions.http_header('Accept', 'application/json'),
          extensions.http_header('Expect', '')
        ],
        'application/json',
        jsonb_build_object('bank_payments', v_bank_payments)::text
      )::extensions.http_request);
    exception when others then
      null;
    end;
  end if;

  -- Reflects immediately in the portal without waiting for the next cron sync pass - harmless even
  -- though OnlineOrders is normally a Pancake -> Supabase mirror, since this is exactly the value
  -- Pancake now actually has.
  update public."OnlineOrders" set "Status" = p_new_status where "OrderID" = p_order_id;

  if p_notify_customer then
    begin
      select s.photo_sent, s.photo_error into v_photo_sent, v_photo_error
      from public._send_online_order_status_message(p_order_id, p_new_status, p_photo_url) s;
      v_message_sent := true;
    exception when others then
      v_message_error := sqlerrm;
    end;
  end if;

  -- Records every photo that was actually captured, sent or not, so staff can look back at what
  -- went out - see public."OnlineOrderStatusPhotos" (supabase_online_order_status_photo.sql).
  if p_photo_url is not null and trim(p_photo_url) <> '' then
    insert into public."OnlineOrderStatusPhotos" ("OrderID", "Status", "StoragePath", "PublicUrl", "SentToCustomer", "SendError", "UploadedBy")
    values (p_order_id, p_new_status, coalesce(p_photo_storage_path, ''), p_photo_url, coalesce(v_photo_sent, false), v_photo_error, p_admin_username);
  end if;

  return query select p_new_status, v_message_sent, v_message_error, v_photo_sent, v_photo_error;
end;
$$;

grant execute on function public.admin_update_online_order_status(text, text, text, text, boolean, text, text, bigint[]) to anon;

-- ---------------------------------------------------------------------------
-- Message sender - builds and sends the same "your order is ready" message the desktop app sends
-- (SendUpdateToCustomerForRowAsync), copied here verbatim template-for-template. Not granted to
-- anon directly - only reachable through admin_update_online_order_status above, which already
-- re-verified staff.
-- ---------------------------------------------------------------------------

drop function if exists public._send_online_order_status_message(text, text);
drop function if exists public._send_online_order_status_message(text, text, text);

-- p_photo_url (optional): per direct request, staff can attach a photo of the packed order (snapped
-- on their phone) to this message. The photo is sent as a SEPARATE, best-effort API call AFTER the
-- text message below has already succeeded - Pancake's exact attachment field/shape is unverified
-- (no usable public docs found for it), so a wrong guess there only costs the photo, never the text
-- message or the status change itself. photo_sent/photo_error report the outcome back up through
-- admin_update_online_order_status. Adjust the jsonb_build_object shape a few lines down once the
-- real one is confirmed against a live test.
create or replace function public._send_online_order_status_message(p_order_id text, p_new_status text, p_photo_url text default null)
returns table(photo_sent boolean, photo_error text)
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
  v_url text;
  v_response extensions.http_response;
  v_photo_sent boolean := false;
  v_photo_error text;
begin
  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found or v_order."Page_ID" is null or v_order."Conversation_ID" is null
     or trim(v_order."Page_ID") = '' or trim(v_order."Conversation_ID") = '' then
    photo_sent := false;
    photo_error := null;
    return next;
    return; -- same "missing Page_ID/Conversation_ID, cannot send" guard as the desktop app
  end if;

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

  v_url := 'https://pages.fm/api/public_api/v1/pages/' || v_order."Page_ID" || '/conversations/' || v_order."Conversation_ID"
    || '/messages?page_access_token=' || public._pancake_public_api_key();

  select * into v_response from extensions.http((
    'POST',
    v_url,
    array[
      extensions.http_header('Accept', 'application/json'),
      extensions.http_header('Expect', '')
    ],
    'application/json',
    jsonb_build_object('action', 'reply_inbox', 'message', v_message)::text
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake messaging API returned HTTP %.', v_response.status;
  end if;

  -- Best-effort photo attachment - see the function header for why this never raises. Tries the
  -- most standard shape for this kind of simplified messaging wrapper (a top-level "attachment"
  -- object); if Pancake actually expects something else, this call fails harmlessly and
  -- photo_error reports why so the real shape can be identified and swapped in here.
  if p_photo_url is not null and trim(p_photo_url) <> '' then
    begin
      select * into v_response from extensions.http((
        'POST',
        v_url,
        array[
          extensions.http_header('Accept', 'application/json'),
          extensions.http_header('Expect', '')
        ],
        'application/json',
        jsonb_build_object(
          'action', 'reply_inbox',
          'attachment', jsonb_build_object('type', 'image', 'url', p_photo_url)
        )::text
      )::extensions.http_request);

      if v_response.status >= 200 and v_response.status < 300 then
        v_photo_sent := true;
      else
        v_photo_error := 'Pancake rejected the photo (HTTP ' || v_response.status || '): ' || left(coalesce(v_response.content, ''), 300);
      end if;
    exception when others then
      v_photo_error := sqlerrm;
    end;
  end if;

  photo_sent := v_photo_sent;
  photo_error := v_photo_error;
  return next;
end;
$$;
