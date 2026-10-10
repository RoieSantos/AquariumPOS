-- AI bot (Vic / website Alice) orders go straight into Online Orders - no Pancake order at all.
-- Per "once the confirm is clicked it will directly go to online orders no need to create pancake
-- orders we will cut it" (and "Portal only, go ahead").
--
-- Flow:
--   1. The bot's create_order (supabase/functions/_shared/chatbot-engine.ts) saves the AutomatedOrders
--      row + lines with PancakeSyncStatus = 'Not Pushed'. Not 'Pending' - cron_process_pending_
--      automated_orders pushes every 'Pending' row to Pancake once a minute.
--   2. Staff review it and click "Confirm Order" (GMA Conversations order card / Automated Orders modal)
--      -> admin_confirm_bot_order creates the OnlineOrders + OnlineOrderLines rows itself, with
--      OrderID = the AO number (e.g. AO-00031) and "Source" = 'Portal'. The bot order becomes
--      Status 'Confirmed', PancakeSyncStatus 'Portal', PancakeReceiptNo = the AO number (that's the
--      key Online Orders already uses to link an order back to its GMA conversation - GMA badge and
--      Messenger routing keep working).
--   3. The order then goes through the normal Online Orders flow (Assign, Production Done, Ready to
--      Ship, Release / Ship). Every Pancake call on the way is skipped for portal-only orders:
--      - _pancake_patch_online_order_status (Assign / To Ship / Shipped / Release all go through it)
--        returns without calling Pancake - each caller already updates OnlineOrders.Status itself.
--      - _sync_online_order_detail (line refresh + the detail cron) just marks the order checked.
--      - admin_get_online_order_detail_live / admin_get_online_order_payment_methods read local data.
--      - cron_refresh_open_online_order_statuses skips them (it would otherwise retry them forever at
--        the front of its queue, crowding out real orders).
--      - staff_save_online_order_set_materials (SET Assemble) writes the parts to OnlineOrderLines.
--      - admin_add_automated_order_payment updates the portal order's Amount Paid / Balance.
--      - admin_portal_order_to_ship: To Ship from Confirmed (there's no POS "Print" for these).
--
-- NOT covered: the desktop POS never sees these orders (it reads online orders from Pancake). The
-- Payment Method report (OnlineOrderPayments, synced from Pancake) doesn't include their payments.
-- Once confirmed, the bot order can't be edited from GMA Conversations / Automated Orders.
--
-- Run AFTER supabase_gma_conversations_staff_rpc_access.sql, supabase_gma_conversation_order_statement_
-- timeout.sql, supabase_gma_payment_pancake_retry.sql, supabase_pancake_patch_keep_payments.sql,
-- supabase_online_order_sync_no_long_locks.sql, supabase_online_order_lines_sku.sql,
-- supabase_payment_methods_master.sql, supabase_online_order_open_refresh_lines.sql and
-- supabase_online_order_set_explode.sql (each function below is a copy of the live definition from
-- those files, with only the portal-only branch added). Safe to re-run.

-- ---------------------------------------------------------------------------
-- 0. OnlineOrders."Source" + helper

alter table public."OnlineOrders" add column if not exists "Source" varchar(20);

create or replace function public._is_portal_only_online_order(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public."OnlineOrders"
    where "OrderID" = trim(coalesce(p_order_id, '')) and "Source" = 'Portal'
  );
$$;

-- The previous (never-run) version of this change pushed bot orders to Pancake - drop it if it exists.
drop function if exists public.admin_push_and_confirm_bot_order(text, text, text);

-- ---------------------------------------------------------------------------
-- 1. admin_confirm_bot_order - staff "Confirm Order" on a bot order: creates the Online Orders entry

drop function if exists public.admin_confirm_bot_order(text, text, text);

create or replace function public.admin_confirm_bot_order(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(online_order_id text, order_status text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_location text;
  v_warehouse_id text;
  v_total numeric(18, 2);
  v_paid numeric(18, 2);
  v_glass text;
  v_confirmed_by text;
  v_now timestamptz := now();
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no for update;
  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  if coalesce(v_order."PancakeSyncStatus", '') <> 'Not Pushed' then
    raise exception 'Order % is %, not an order waiting for confirmation.', p_order_no, coalesce(v_order."PancakeSyncStatus", 'unknown');
  end if;
  if v_order."Status" in ('Completed', 'Cancelled') then
    raise exception 'Order % is % and can''t be confirmed.', p_order_no, v_order."Status";
  end if;
  if not exists (select 1 from public."AutomatedOrderLines" where "OrderNo" = p_order_no) then
    raise exception 'Order % has no items.', p_order_no;
  end if;
  if exists (select 1 from public."OnlineOrders" where "OrderID" = p_order_no) then
    raise exception 'Order % is already in Online Orders.', p_order_no;
  end if;

  -- Same branch -> warehouse match as _push_automated_order_to_pancake.
  v_location := coalesce(nullif(trim(v_order."Location"), ''), 'Amaya');
  select "ID" into v_warehouse_id
  from public."Warehouses"
  where "Name" ilike '%' || v_location || '%'
  order by "Name"
  limit 1;
  if v_warehouse_id is null then
    raise exception 'No Warehouses row matches location "%".', v_location;
  end if;

  select coalesce(sum(l."Quantity" * l."Price"), 0) into v_total
  from public."AutomatedOrderLines" l where l."OrderNo" = p_order_no;
  select coalesce(sum(p."Amount"), 0) into v_paid
  from public."AutomatedOrderPayments" p where p."OrderNo" = p_order_no;

  -- Same 12mm / 10mm flag rule as _sync_online_order_detail.
  select case
           when bool_or(regexp_replace(coalesce(l."ItemName", '') || coalesce(l."Notes", '') || coalesce(l."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%12mm%') then '12mm'
           when bool_or(regexp_replace(coalesce(l."ItemName", '') || coalesce(l."Notes", '') || coalesce(l."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%10mm%') then '10mm'
         end
    into v_glass
  from public."AutomatedOrderLines" l where l."OrderNo" = p_order_no;

  select coalesce(nullif(trim("DisplayName"), ''), "Username") into v_confirmed_by
  from public."StaffUsers" where "Username" = p_admin_username;

  insert into public."OnlineOrders" (
    "OrderID", "Date", "Time", "Status", "CustomerName", "LocationID",
    "MoneyToCollect", "AmountPaid", "Discount", "Balance",
    "ForDelivery", "ShippingAddress", "ShippingPhone", "PrintCount",
    "Last_Updated_At", "SyncedAtUtc", "ReceivedAtShop",
    "GlassThickness", "GlassThicknessCheckedAt", "NotePrintCheckedAt",
    "CreatedBy", "ConfirmedBy", "ConfirmedAtUtc", "Source"
  ) values (
    p_order_no,
    (v_now at time zone 'Asia/Manila')::date,
    to_char(v_now at time zone 'Asia/Manila', 'HH24:MI:SS'),
    'Confirmed',
    v_order."CustomerName",
    v_warehouse_id,
    v_total, v_paid, 0, v_total - v_paid,
    v_order."FulfillmentType" = 'Delivery',
    v_order."DeliveryAddress",
    v_order."CustomerPhone",
    0,
    v_now, v_now, false,
    v_glass, v_now, v_now,
    -- 'AI Bot' for a bot order; the staff username for a GMA "+ New Order" (supabase_gma_new_order_no_pancake.sql).
    coalesce(nullif(trim(v_order."UpdatedBy"), ''), 'AI Bot'), coalesce(v_confirmed_by, p_admin_username), v_now, 'Portal'
  );

  -- Custom lines (CUSTOM-AQUARIUM / -STAND / -STICKER, no ItemCode) take the placeholder product's
  -- code - the same Items row the Pancake push used to tag them with - so maker / custom / glass
  -- detection and the Item Ledger see them like any other custom order line.
  insert into public."OnlineOrderLines" (
    "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price",
    "Discount", "GrossAmount", "NetAmount", "Note", "Description", "SyncedAtUtc"
  )
  select
    p_order_no,
    l."EntryNo"::text,
    coalesce(l."ItemCode", ci."Code", l."CategoryCode"),
    coalesce(l."ItemCode", ci."Code", l."CategoryCode"),
    coalesce(nullif(trim(l."VariationId"), ''), nullif(trim(i."VariationId"), ''), nullif(trim(ci."VariationId"), '')),
    l."Quantity", null, l."Price",
    0, l."Quantity" * l."Price", l."Quantity" * l."Price",
    l."Notes",
    left(l."ItemName", 500),
    v_now
  from public."AutomatedOrderLines" l
  left join public."Items" i on i."Code" = l."ItemCode"
  left join lateral (
    select c."Code", c."VariationId" from public."Items" c
    where l."ItemCode" is null and (c."Name" = l."CategoryCode" or c."Code" = l."CategoryCode")
    order by c."IsActive" desc, (c."Code" = l."CategoryCode") desc
    limit 1
  ) ci on true
  where l."OrderNo" = p_order_no;

  update public."AutomatedOrders"
  set "Status" = 'Confirmed',
      "PancakeSyncStatus" = 'Portal',
      "PancakeSyncError" = null,
      "PancakeReceiptNo" = p_order_no,
      "UpdatedBy" = p_admin_username,
      "UpdatedAtUtc" = v_now
  where "OrderNo" = p_order_no;

  return query select p_order_no::text, 'Confirmed'::text;
end;
$$;

grant execute on function public.admin_confirm_bot_order(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. admin_portal_order_to_ship - To Ship for a portal-only order. These never get a POS "Print",
--    so Confirmed is allowed (moved to Printed first, the same trick admin_ship_online_order_from_stock
--    uses), then the regular admin_update_online_order_status does the rest (serials, message).

drop function if exists public.admin_portal_order_to_ship(text, text, text, text, boolean, bigint[], jsonb);

create or replace function public.admin_portal_order_to_ship(
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
set statement_timeout = '50000'
set lock_timeout = '10000'
as $$
declare
  v_status text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._is_portal_only_online_order(p_order_id) then
    raise exception 'Order % is not a portal-only order.', p_order_id;
  end if;

  begin
    select lower(trim(coalesce("Status", ''))) into v_status from public."OnlineOrders" where "OrderID" = p_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (another update is still running on it). Wait a minute, refresh and try again.', p_order_id;
  end;
  if v_status not in ('confirmed', 'submitted', 'printed', 'assigned') then
    raise exception 'Order % is %, it can''t go To Ship from here.', p_order_id, v_status;
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

grant execute on function public.admin_portal_order_to_ship(text, text, text, text, boolean, bigint[], jsonb) to anon;

-- ---------------------------------------------------------------------------
-- 3. admin_update_automated_order - live def + a bot draft (Not Pushed) stays a draft when edited, and a confirmed (Portal) order can't be edited here

drop function if exists public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb);

create or replace function public.admin_update_automated_order(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_lines jsonb
)
returns table(order_no text, estimated_total numeric, pancake_sync_status text, pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '90000'
as $$
declare
  v_current_status text;
  v_current_sync_status text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "Status", "PancakeSyncStatus" into v_current_status, v_current_sync_status
  from public."AutomatedOrders"
  where "OrderNo" = p_order_no;

  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  if v_current_status in ('Completed', 'Cancelled') then
    raise exception 'This order is % and can no longer be edited.', v_current_status;
  end if;
  -- Already confirmed into Online Orders (portal-only): the Online Orders entry is the live order now.
  if v_current_sync_status = 'Portal' then
    raise exception 'Order % is already confirmed into Online Orders and can no longer be edited here.', p_order_no;
  end if;

  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
  if regexp_replace(p_customer_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Please provide a valid PH mobile number, e.g. 09171234567.';
  end if;
  if v_fulfillment not in ('Pickup', 'Delivery') then
    raise exception 'Fulfillment type must be Pickup or Delivery.';
  end if;
  if v_fulfillment = 'Delivery' and (p_delivery_address is null or trim(p_delivery_address) = '') then
    raise exception 'Delivery address is required for delivery orders.';
  end if;
  if v_location not in ('Amaya', 'GMA') then
    raise exception 'Location must be Amaya or GMA.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one item is required.';
  end if;

  update public."AutomatedOrders"
  set "CustomerName" = trim(p_customer_name),
      "CustomerPhone" = trim(p_customer_phone),
      "CustomerEmail" = nullif(trim(coalesce(p_customer_email, '')), ''),
      "FulfillmentType" = v_fulfillment,
      "DeliveryAddress" = case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
      "Notes" = nullif(trim(coalesce(p_notes, '')), ''),
      "Location" = v_location,
      "UpdatedBy" = p_admin_username,
      "UpdatedAtUtc" = now()
  where "OrderNo" = p_order_no;

  delete from public."AutomatedOrderLines" where "OrderNo" = p_order_no;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);
    v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId")
    values
      (p_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price,
       nullif(trim(coalesce(v_line->>'note', '')), ''), nullif(trim(coalesce(v_line->>'variation_id', '')), ''));

    v_total := v_total + (v_qty * v_price);
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = p_order_no;

  if v_current_sync_status = 'Synced' then
    begin
      perform public._update_automated_order_items_in_pancake(p_order_no);
    exception when others then
      update public."AutomatedOrders"
      set "PancakeSyncStatus" = 'Stale',
          "PancakeSyncError" = 'Order was edited in the portal, but updating the live Pancake order failed: ' || sqlerrm
      where "OrderNo" = p_order_no;
    end;
  elsif coalesce(v_current_sync_status, '') not in ('Not Pushed', 'Portal') then
    -- A bot draft (Not Pushed) stays a draft when staff edit it - only Confirm Order moves it on.
    perform public._push_automated_order_to_pancake(p_order_no);
  end if;

  return query
    select o."OrderNo"::text, o."EstimatedTotal", o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = p_order_no;
end;
$$;

grant execute on function public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb) to anon;

-- ---------------------------------------------------------------------------
-- 4. _pancake_patch_online_order_status - live def (supabase_pancake_patch_keep_payments.sql) + skip portal-only orders

create or replace function public._pancake_patch_online_order_status(p_order_id text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id
    || '?api_key=' || public._pancake_api_key() || '&page_size=1000';
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_snapshot_ok boolean := false;
  v_snapshot_id bigint;
  v_restore_error text;
  v_patch_response extensions.http_response;
  v_attempt int := 0;
  v_max_attempts int := 3;
  v_last_error text;
begin
  -- Portal-only orders (OnlineOrders."Source" = 'Portal', supabase_bot_orders_portal_confirm.sql) have no
  -- Pancake order - every status change is local only, so there is nothing to send.
  if public._is_portal_only_online_order(p_order_id) then
    return;
  end if;

  -- 8s per call keeps the worst case inside the 60s limit of admin_sync_online_order_assigned_status,
  -- which also sends the customer message afterwards.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');

  -- 1. Snapshot bank_payments (Pancake's PATCH wipes them). Required - no snapshot, no PATCH.
  for i in 1..2 loop
    begin
      select * into v_get_response from extensions.http_get(v_order_url);
      if v_get_response.status >= 200 and v_get_response.status < 300 then
        v_get_body := v_get_response.content::jsonb;
        v_order_obj := case
          when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
          when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
          else v_get_body
        end;
        if jsonb_typeof(v_order_obj) = 'object' then
          v_bank_payments := case when jsonb_typeof(v_order_obj -> 'bank_payments') = 'object'
                                  then v_order_obj -> 'bank_payments' end;
          v_snapshot_ok := true;
          exit;
        end if;
      end if;
      v_last_error := format('HTTP %s', v_get_response.status);
    exception when others then
      v_last_error := sqlerrm;
    end;
    if i < 2 then perform pg_sleep(1); end if;
  end loop;

  if not v_snapshot_ok then
    raise exception 'Could not read order % from Pancake to keep its payments (%). Nothing was changed - please try again in a moment.', p_order_id, v_last_error;
  end if;

  if v_bank_payments is not null and v_bank_payments <> '{}'::jsonb then
    insert into public."PancakeBankPaymentSnapshots" ("OrderID", "BankPayments", "StatusPayload")
    values (p_order_id, v_bank_payments, p_payload)
    returning "ID" into v_snapshot_id;
  end if;

  -- 2. The status PATCH (unchanged: up to 3 tries, 5xx retried, 4xx is a real rejection).
  v_last_error := null;
  loop
    v_attempt := v_attempt + 1;
    begin
      select * into v_patch_response from extensions.http((
        'PATCH', v_order_url,
        array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
        'application/json',
        p_payload::text
      )::extensions.http_request);
      exit when v_patch_response.status < 500;
      v_last_error := format('HTTP %s', v_patch_response.status);
    exception when others then
      v_last_error := sqlerrm;
    end;

    if v_attempt >= v_max_attempts then
      raise exception 'Could not reach Pancake after % tries (%). The status was not changed on the portal - please try again in a moment.', v_max_attempts, v_last_error;
    end if;
    perform pg_sleep(v_attempt);
  end loop;

  if v_patch_response.status < 200 or v_patch_response.status >= 300 then
    raise exception 'Pancake rejected the status update (HTTP %).', v_patch_response.status;
  end if;

  -- 3. Put the payments back - checked, retried, and recorded either way.
  if v_snapshot_id is not null then
    v_restore_error := public._pancake_put_bank_payments(p_order_id, v_bank_payments);
    update public."PancakeBankPaymentSnapshots"
    set "Restored" = v_restore_error is null, "RestoreError" = v_restore_error
    where "ID" = v_snapshot_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. _sync_online_order_detail - live def (supabase_online_order_sync_no_long_locks.sql) + skip portal-only orders

create or replace function public._sync_online_order_detail(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_response extensions.http_response;
  v_body jsonb;
  v_el jsonb;
  v_item jsonb;
  v_info jsonb;
  v_pdid text;
  v_variation_id text;
  v_qty numeric;
  v_price numeric;
  v_name text;
  v_note text;
  v_line_id text;
  v_seen text[] := array[]::text[];
  v_has_12 boolean := false;
  v_has_10 boolean := false;
  v_note_print text;
begin
  -- Portal-only orders have no Pancake order to read - mark them checked so the detail cron skips them.
  if public._is_portal_only_online_order(p_order_id) then
    update public."OnlineOrders"
    set "GlassThicknessCheckedAt" = now(), "NotePrintCheckedAt" = now()
    where "OrderID" = p_order_id;
    return;
  end if;

  v_response := extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id
    || '?api_key=' || public._pancake_api_key() || '&page_size=1000');
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake detail HTTP %', v_response.status;
  end if;

  v_body := v_response.content::jsonb;
  v_el := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' then v_body
    else null
  end;
  if v_el is null then
    raise exception 'Pancake returned no order';
  end if;

  if jsonb_typeof(v_el -> 'items') = 'array' then
    for v_item in select * from jsonb_array_elements(v_el -> 'items')
    loop
      begin
        v_info := v_item -> 'variation_info';
        v_pdid := coalesce(v_info ->> 'product_display_id', v_item ->> 'product_display_id');
        v_name := coalesce(v_info ->> 'name', v_item ->> 'name');
        v_note := v_item ->> 'note';

        if regexp_replace(coalesce(v_name, '') || ' ' || coalesce(v_note, '') || ' ' || coalesce(v_pdid, ''), '[[:space:]]+', '', 'g') ilike '%12mm%' then
          v_has_12 := true;
        elsif regexp_replace(coalesce(v_name, '') || ' ' || coalesce(v_note, '') || ' ' || coalesce(v_pdid, ''), '[[:space:]]+', '', 'g') ilike '%10mm%' then
          v_has_10 := true;
        end if;

        if v_pdid is null or trim(v_pdid) = '' then
          continue;
        end if;

        v_variation_id := coalesce(v_info ->> 'variation_id', v_item ->> 'variation_id', v_item ->> 'variationId');
        v_qty := public.pancake_parse_decimal(v_item ->> 'quantity');
        v_price := public.pancake_parse_decimal(coalesce(v_info ->> 'retail_price', v_item ->> 'retail_price'));
        v_line_id := coalesce(
          v_item ->> 'line_id', v_item ->> 'id', v_item ->> 'order_line_id',
          v_item ->> 'order_item_id', v_item ->> 'item_id', ''
        );

        insert into public."OnlineOrderLines" (
          "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "GrossAmount", "Note", "Description", "SyncedAtUtc"
        ) values (
          p_order_id, v_line_id, v_pdid, v_pdid, nullif(v_variation_id, ''), v_qty, null, v_price, v_price * v_qty, nullif(v_note, ''), nullif(v_name, ''), now()
        )
        on conflict ("OrderID", "LineID") do update set
          "ItemCode" = excluded."ItemCode",
          "product_display_id" = excluded."product_display_id",
          "VariationId" = excluded."VariationId",
          "Quantity" = excluded."Quantity",
          "Price" = excluded."Price",
          "GrossAmount" = excluded."GrossAmount",
          "Note" = excluded."Note",
          "Description" = excluded."Description",
          "SyncedAtUtc" = now();

        v_seen := array_append(v_seen, v_line_id);
      exception when others then
        null; -- skip malformed line, keep processing the rest
      end;
    end loop;

    -- Only when Pancake returned at least one line, so a bad response never wipes an order.
    if cardinality(v_seen) > 0 then
      delete from public."OnlineOrderLines" l
      where l."OrderID" = p_order_id and not (l."LineID" = any(v_seen));
    end if;
  end if;

  v_note_print := nullif(trim(coalesce(v_el ->> 'note_print', v_el ->> 'notePrint', '')), '');
  update public."OnlineOrders"
    set "GlassThickness" = case when v_has_12 then '12mm' when v_has_10 then '10mm' else null end,
        "GlassThicknessCheckedAt" = now(),
        "NotePrint" = coalesce(v_note_print, "NotePrint"),
        "NotePrintCheckedAt" = now()
    where "OrderID" = p_order_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. admin_get_online_order_detail_live - live def (supabase_online_order_lines_sku.sql) + local read for portal-only orders

create or replace function public.admin_get_online_order_detail_live(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(
  order_id text,
  status text,
  customer_name text,
  line_id text,
  item_code text,
  product_display_id text,
  variation_id text,
  quantity numeric,
  price numeric,
  gross_amount numeric,
  description text,
  note text,
  order_note text,
  sku text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_detail_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_order_el jsonb;
  v_status_raw text;
  v_status text;
  v_customer text;
  v_order_note text;
  v_line_items jsonb;
  v_line_item jsonb;
  v_variation_info jsonb;
  v_product_display_id text;
  v_variation_id text;
  v_qty numeric;
  v_price numeric;
  v_line_name text;
  v_line_id text;
  v_line_note text;
  v_row_count int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_order_id is null or trim(p_order_id) = '' then
    raise exception 'Order ID is required.';
  end if;

  -- Portal-only orders (supabase_bot_orders_portal_confirm.sql) have no Pancake order - read the
  -- header and lines straight from OnlineOrders / OnlineOrderLines instead.
  if public._is_portal_only_online_order(p_order_id) then
    return query
      select
        o."OrderID"::text,
        o."Status"::text,
        o."CustomerName"::text,
        l."LineID"::text,
        l."ItemCode"::text,
        l."product_display_id"::text,
        l."VariationId"::text,
        l."Quantity"::numeric,
        l."Price"::numeric,
        l."GrossAmount"::numeric,
        l."Description"::text,
        l."Note"::text,
        (select ao."Notes"::text from public."AutomatedOrders" ao where ao."OrderNo" = o."OrderID" limit 1),
        coalesce(
          (select nullif(trim(v."SKU"), '') from public."Variants" v
            where v."VariationId" = l."VariationId" and nullif(trim(v."SKU"), '') is not null limit 1),
          (select nullif(trim(i."SKU"), '') from public."Items" i
            where i."Code" = l."ItemCode" and nullif(trim(i."SKU"), '') is not null limit 1),
          l."ItemCode"
        )::text
      from public."OnlineOrders" o
      left join public."OnlineOrderLines" l on l."OrderID" = o."OrderID"
      where o."OrderID" = trim(p_order_id)
      order by length(l."LineID"), l."LineID";
    return;
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  v_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || p_order_id || '?api_key=' || v_api_key || '&page_size=1000';
  v_response := extensions.http_get(v_detail_url);
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake order detail request failed (HTTP %).', v_response.status;
  end if;

  v_body := v_response.content::jsonb;
  v_order_el := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' then v_body
    else null
  end;

  if v_order_el is null then
    raise exception 'Order % not found.', p_order_id;
  end if;

  v_status_raw := coalesce(v_order_el ->> 'status_name', v_order_el ->> 'status', v_order_el ->> 'state', v_order_el ->> 'order_status');
  v_status := case lower(trim(v_status_raw))
    when 'submitted' then 'Confirmed'
    when 'packing' then 'To Ship'
    when 'packed' then 'To Ship'
    when 'pending' then 'Pending Transfer'
    when '9' then 'Pending Transfer'
    when 'pending_transfer' then 'Pending Transfer'
    when 'pending transfer' then 'Pending Transfer'
    when 'waiting_for_pickup' then 'Pending Transfer'
    when 'waiting for pickup' then 'Pending Transfer'
    when '12' then 'In-Transit'
    when 'wait_print' then 'In-Transit'
    when 'wait print' then 'In-Transit'
    when 'in_transit' then 'In-Transit'
    when 'in-transit' then 'In-Transit'
    when 'shipped' then 'Shipped'
    when 'delivered' then 'Shipped'
    when '2' then 'Shipped'
    when 'received' then 'Received'
    when '3' then 'Received'
    when 'printed' then 'Printed'
    else v_status_raw
  end;

  v_customer := coalesce(
    v_order_el -> 'customer' ->> 'name', v_order_el -> 'customer' ->> 'customer_name', v_order_el -> 'customer' ->> 'full_name',
    v_order_el ->> 'customer_name', v_order_el ->> 'customer', v_order_el ->> 'client_name', v_order_el ->> 'buyer_name'
  );

  -- Order-level note: for walk-ins, the POS receipt description (see header comment).
  v_order_note := nullif(trim(coalesce(v_order_el ->> 'note', '')), '');

  v_line_items := case
    when jsonb_typeof(v_order_el -> 'items') = 'array' then v_order_el -> 'items'
    else '[]'::jsonb
  end;

  for v_line_item in select * from jsonb_array_elements(v_line_items)
  loop
    begin
      v_variation_info := v_line_item -> 'variation_info';
      v_product_display_id := coalesce(v_variation_info ->> 'product_display_id', v_line_item ->> 'product_display_id');
      if v_product_display_id is null or trim(v_product_display_id) = '' then
        continue;
      end if;

      v_variation_id := coalesce(v_variation_info ->> 'variation_id', v_line_item ->> 'variation_id', v_line_item ->> 'variationId');
      v_qty := public.pancake_parse_decimal(v_line_item ->> 'quantity');
      v_price := public.pancake_parse_decimal(coalesce(v_variation_info ->> 'retail_price', v_line_item ->> 'retail_price'));
      v_line_name := coalesce(v_variation_info ->> 'name', v_line_item ->> 'name');
      v_line_id := coalesce(
        v_line_item ->> 'line_id', v_line_item ->> 'id', v_line_item ->> 'order_line_id',
        v_line_item ->> 'order_item_id', v_line_item ->> 'item_id', ''
      );
      v_line_note := v_line_item ->> 'note';

      v_row_count := v_row_count + 1;
      order_id := p_order_id;
      status := v_status;
      customer_name := v_customer;
      line_id := v_line_id;
      item_code := v_product_display_id;
      product_display_id := v_product_display_id;
      variation_id := nullif(v_variation_id, '');
      quantity := v_qty;
      price := v_price;
      gross_amount := v_price * v_qty;
      description := nullif(v_line_name, '');
      note := nullif(v_line_note, '');
      order_note := v_order_note;
      sku := coalesce(
        (select nullif(trim(v."SKU"), '') from public."Variants" v
          where v."VariationId" = nullif(v_variation_id, '') and nullif(trim(v."SKU"), '') is not null limit 1),
        (select nullif(trim(i."SKU"), '') from public."Items" i
          where i."Code" = v_product_display_id and nullif(trim(i."SKU"), '') is not null limit 1),
        v_product_display_id
      );
      return next;
    exception when others then
      null; -- skip malformed line, keep processing the rest
    end;
  end loop;

  if v_row_count = 0 then
    order_id := p_order_id;
    status := v_status;
    customer_name := v_customer;
    line_id := null;
    item_code := null;
    product_display_id := null;
    variation_id := null;
    quantity := null;
    price := null;
    gross_amount := null;
    description := null;
    note := null;
    order_note := v_order_note;
    sku := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_online_order_detail_live(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 7. admin_get_online_order_payment_methods - live def (supabase_payment_methods_master.sql) + local read for portal-only orders

create or replace function public.admin_get_online_order_payment_methods(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(method text, code text, amount numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_response extensions.http_response;
  v_body jsonb;
  v_order_el jsonb;
  v_key text;
  v_value jsonb;
  v_amount numeric;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_order_id is null or trim(p_order_id) = '' then
    raise exception 'Order ID is required.';
  end if;

  -- Portal-only orders: payments live on the originating bot order (AutomatedOrderPayments).
  if public._is_portal_only_online_order(p_order_id) then
    return query
      select p."Method"::text, p."Method"::text, sum(p."Amount")::numeric
      from public."AutomatedOrderPayments" p
      where p."OrderNo" = trim(p_order_id)
      group by p."Method"
      order by 1;
    return;
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  v_response := extensions.http_get(
    v_base_url || '/shops/' || v_shop_id || '/orders/' || trim(p_order_id) || '?api_key=' || v_api_key
  );
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake order request failed (HTTP %).', v_response.status;
  end if;

  v_body := v_response.content::jsonb;
  v_order_el := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body -> 'order') = 'object' then v_body -> 'order'
    when jsonb_typeof(v_body) = 'object' then v_body
    else null
  end;
  if v_order_el is null then
    return;
  end if;

  begin
    v_amount := nullif(trim(coalesce(v_order_el ->> 'cash', '')), '')::numeric;
  exception when others then
    v_amount := null;
  end;
  if coalesce(v_amount, 0) > 0 then
    method := public._payment_method_label('CASH');
    code := 'CASH';
    amount := v_amount;
    return next;
  end if;

  if jsonb_typeof(v_order_el -> 'bank_payments') = 'object' then
    for v_key, v_value in select * from jsonb_each(v_order_el -> 'bank_payments') loop
      begin
        v_amount := case
          when jsonb_typeof(v_value) = 'object' then coalesce(v_value ->> 'amount', v_value ->> 'value')::numeric
          else (v_value #>> '{}')::numeric
        end;
      exception when others then
        v_amount := null;
      end;
      if coalesce(v_amount, 0) > 0 then
        perform public._payment_method_touch(v_key);
        method := public._payment_method_label(v_key);
        code := v_key;
        amount := v_amount;
        return next;
      end if;
    end loop;
  end if;
end;
$$;

grant execute on function public.admin_get_online_order_payment_methods(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 8. cron_refresh_open_online_order_statuses - live def (supabase_online_order_open_refresh_lines.sql) + skip portal-only orders

create or replace function public.cron_refresh_open_online_order_statuses(
  p_max_orders int default 40
)
returns table(orders_checked int, orders_changed int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_max int := least(greatest(coalesce(p_max_orders, 40), 1), 200);
  v_order_id text;
  v_old_status text;
  v_response extensions.http_response;
  v_body jsonb;
  v_el jsonb;
  v_status_raw text;
  v_status text;
  v_updated_raw text;
  v_updated_utc timestamptz;
  v_checked int := 0;
  v_changed int := 0;
  v_line_item jsonb;
  v_variation_info jsonb;
  v_product_display_id text;
  v_variation_id text;
  v_qty numeric;
  v_price numeric;
  v_line_name text;
  v_line_note text;
  v_line_id text;
  v_seen text[];
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');

  for v_order_id, v_old_status in
    select "OrderID", "Status" from public."OnlineOrders"
    where "Status" in ('Confirmed', 'Printed', 'Assigned', 'To Ship', 'In-Transit', 'Pending Transfer')
      and coalesce("ReceivedAtShop", false) is not true
      and coalesce("Source", '') <> 'Portal'
    order by "SyncedAtUtc" asc nulls first
    limit v_max
  loop
    begin
      v_response := extensions.http_get(
        v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order_id || '?api_key=' || v_api_key || '&page_size=1000'
      );
      if v_response.status < 200 or v_response.status >= 300 then
        continue; -- retried on a future run
      end if;

      v_body := v_response.content::jsonb;
      v_el := case
        when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
        when jsonb_typeof(v_body) = 'object' then v_body
        else null
      end;
      if v_el is null then
        continue;
      end if;

      v_status_raw := coalesce(v_el ->> 'status_name', v_el ->> 'status', v_el ->> 'state', v_el ->> 'order_status');
      if v_status_raw is null or lower(trim(v_status_raw)) in ('', 'new') then
        continue;
      end if;

      v_status := case lower(trim(v_status_raw))
        when 'submitted' then 'Confirmed'
        when 'packing' then 'To Ship'
        when 'packed' then 'To Ship'
        when 'pending' then 'Pending Transfer'
        when '9' then 'Pending Transfer'
        when 'pending_transfer' then 'Pending Transfer'
        when 'pending transfer' then 'Pending Transfer'
        when 'waiting_for_pickup' then 'Pending Transfer'
        when 'waiting for pickup' then 'Pending Transfer'
        when '12' then 'In-Transit'
        when 'wait_print' then 'In-Transit'
        when 'wait print' then 'In-Transit'
        when 'in_transit' then 'In-Transit'
        when 'in-transit' then 'In-Transit'
        when 'shipped' then 'Shipped'
        when 'delivered' then 'Shipped'
        when '2' then 'Shipped'
        when 'received' then 'Received'
        when '3' then 'Received'
        when 'printed' then 'Printed'
        else v_status_raw
      end;

      v_checked := v_checked + 1;

      v_updated_raw := coalesce(v_el ->> 'updated_at', v_el ->> 'last_updated_at');
      begin
        v_updated_utc := v_updated_raw::timestamptz;
      exception when others then
        v_updated_utc := null;
      end;

      update public."OnlineOrders"
        set "Status" = v_status,
            "Last_Updated_At" = coalesce(v_updated_utc, "Last_Updated_At"),
            "SyncedAtUtc" = now()
        where "OrderID" = v_order_id;

      if v_status is distinct from v_old_status then
        v_changed := v_changed + 1;
      end if;

      -- Lines: same mapping as the cron sync's lines pass (supabase_pancake_manual_sync.sql).
      if jsonb_typeof(v_el -> 'items') = 'array' then
        v_seen := array[]::text[];
        for v_line_item in select * from jsonb_array_elements(v_el -> 'items')
        loop
          begin
            v_variation_info := v_line_item -> 'variation_info';
            v_product_display_id := coalesce(v_variation_info ->> 'product_display_id', v_line_item ->> 'product_display_id');
            if v_product_display_id is null or trim(v_product_display_id) = '' then
              continue;
            end if;

            v_variation_id := coalesce(v_variation_info ->> 'variation_id', v_line_item ->> 'variation_id', v_line_item ->> 'variationId');
            v_qty := public.pancake_parse_decimal(v_line_item ->> 'quantity');
            v_price := public.pancake_parse_decimal(coalesce(v_variation_info ->> 'retail_price', v_line_item ->> 'retail_price'));
            v_line_name := coalesce(v_variation_info ->> 'name', v_line_item ->> 'name');
            v_line_note := v_line_item ->> 'note';
            v_line_id := coalesce(
              v_line_item ->> 'line_id', v_line_item ->> 'id', v_line_item ->> 'order_line_id',
              v_line_item ->> 'order_item_id', v_line_item ->> 'item_id', ''
            );

            insert into public."OnlineOrderLines" (
              "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "GrossAmount", "Note", "Description", "SyncedAtUtc"
            ) values (
              v_order_id, v_line_id, v_product_display_id, v_product_display_id, nullif(v_variation_id, ''), v_qty, null, v_price, v_price * v_qty, nullif(v_line_note, ''), nullif(v_line_name, ''), now()
            )
            on conflict ("OrderID", "LineID") do update set
              "ItemCode" = excluded."ItemCode",
              "product_display_id" = excluded."product_display_id",
              "VariationId" = excluded."VariationId",
              "Quantity" = excluded."Quantity",
              "Price" = excluded."Price",
              "GrossAmount" = excluded."GrossAmount",
              "Note" = excluded."Note",
              "Description" = excluded."Description",
              "SyncedAtUtc" = now();

            v_seen := array_append(v_seen, v_line_id);
          exception when others then
            null; -- skip malformed line, keep processing the rest
          end;
        end loop;

        if cardinality(v_seen) > 0 then
          delete from public."OnlineOrderLines" l
          where l."OrderID" = v_order_id and not (l."LineID" = any(v_seen));
        end if;
      end if;
    exception when others then
      null; -- skip this order, retried on a future run
    end;
  end loop;

  return query select v_checked, v_changed;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. admin_add_automated_order_payment - live def (supabase_gma_payment_pancake_retry.sql) + portal orders update Online Orders, not Pancake

create or replace function public.admin_add_automated_order_payment(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_amount numeric,
  p_method text,
  p_reference text
)
returns table(pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '60000'
as $$
declare
  v_method text := coalesce(nullif(trim(p_method), ''), 'Cash');
  v_bank_key text;
  v_order public."AutomatedOrders"%rowtype;
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_order_url text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_existing_amount numeric;
  v_patch_response extensions.http_response;
  v_attempt int;
  v_max_attempts int := 3;
  v_last_error text;
  v_sync_error text;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_order_no is null or trim(p_order_no) = '' then
    raise exception 'OrderNo is required.';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception 'Amount is required.';
  end if;

  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;

  insert into public."AutomatedOrderPayments" ("OrderNo", "Amount", "Method", "Reference", "RecordedBy")
  values (p_order_no, p_amount, v_method, nullif(trim(coalesce(p_reference, '')), ''), p_admin_username);

  -- Confirmed into Online Orders without Pancake (supabase_bot_orders_portal_confirm.sql): the payment
  -- goes onto the portal order's Amount Paid / Balance instead of Pancake's bank_payments.
  if v_order."PancakeSyncStatus" = 'Portal' then
    update public."OnlineOrders" o
    set "AmountPaid" = coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = p_order_no), 0),
        "Balance" = coalesce(o."MoneyToCollect", 0)
                    - coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = p_order_no), 0),
        "LastPaid_Date" = (now() at time zone 'Asia/Manila')::date,
        "LastPaid_Time" = to_char(now() at time zone 'Asia/Manila', 'HH24:MI:SS')
    where o."OrderID" = p_order_no;
    return query select null::text;
    return;
  end if;

  v_bank_key := case lower(v_method)
    when 'gcash' then 'GCASH'
    when 'bdo' then 'BDO'
    when 'metrobank' then 'METROBANK'
    when 'bank transfer' then 'Bank Transfer'
    else null
  end;

  if v_bank_key is not null and v_order."PancakeReceiptNo" is not null then
    begin
      v_order_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order."PancakeReceiptNo" || '?api_key=' || v_api_key || '&page_size=1000';

      -- 8s per call keeps the worst case (3 GETs + 3 PATCHes + pauses, ~54s) inside the 60s limit.
      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');

      -- GET (read-only, always safe to retry).
      v_attempt := 0;
      loop
        v_attempt := v_attempt + 1;
        begin
          select * into v_get_response from extensions.http_get(v_order_url);
          exit when v_get_response.status < 500;
          v_last_error := format('HTTP %s', v_get_response.status);
        exception when others then
          v_last_error := sqlerrm;
        end;
        if v_attempt >= v_max_attempts then
          raise exception 'Could not reach Pancake after % tries (%)', v_max_attempts, v_last_error;
        end if;
        perform pg_sleep(v_attempt);
      end loop;

      if v_get_response.status < 200 or v_get_response.status >= 300 then
        raise exception 'Could not read the order from Pancake (HTTP %).', v_get_response.status;
      end if;

      v_get_body := v_get_response.content::jsonb;
      v_order_obj := case
        when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
        when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
        else v_get_body
      end;
      v_bank_payments := case when jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then v_order_obj -> 'bank_payments' else '{}'::jsonb end;

      v_existing_amount := coalesce((v_bank_payments ->> v_bank_key)::numeric, 0);
      v_bank_payments := v_bank_payments || jsonb_build_object(v_bank_key, v_existing_amount + p_amount);

      -- PATCH the same absolute totals on every try - idempotent, so a retry can't double-add.
      v_attempt := 0;
      loop
        v_attempt := v_attempt + 1;
        begin
          select * into v_patch_response from extensions.http((
            'PATCH',
            v_order_url,
            array[
              extensions.http_header('Accept', 'application/json'),
              extensions.http_header('Expect', '')
            ],
            'application/json',
            jsonb_build_object('bank_payments', v_bank_payments)::text
          )::extensions.http_request);
          exit when v_patch_response.status < 500;
          v_last_error := format('HTTP %s', v_patch_response.status);
        exception when others then
          v_last_error := sqlerrm;
        end;
        if v_attempt >= v_max_attempts then
          raise exception 'Could not reach Pancake after % tries (%)', v_max_attempts, v_last_error;
        end if;
        perform pg_sleep(v_attempt);
      end loop;

      if v_patch_response.status < 200 or v_patch_response.status >= 300 then
        raise exception 'Pancake rejected the bank_payments update (HTTP %): %', v_patch_response.status, left(v_patch_response.content, 300);
      end if;
    exception when others then
      v_sync_error := sqlerrm;
    end;
  end if;

  return query select v_sync_error;
end;
$$;

grant execute on function public.admin_add_automated_order_payment(text, text, text, numeric, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 10. SET Assemble for portal-only orders

-- Portal-only twin of staff_save_online_order_set_materials (supabase_online_order_set_explode.sql):
-- same package/material logic (the loop below is copied verbatim), but it reads and writes
-- OnlineOrderLines directly instead of the Pancake order. Called by that function for portal-only orders.
drop function if exists public._save_portal_order_set_materials(text, jsonb);

create or replace function public._save_portal_order_set_materials(p_order_id text, p_sets jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_set jsonb;
  v_set_idx int;
  v_mat jsonb;
  v_parent record;
  v_display text;
  v_material_note text;
  v_summary text;
  v_kept_note text;
  v_mat_qty numeric;
  v_mat_variation text;
  v_mat_code text;
  v_mat_name text;
  v_next_ord int;
  v_material_count int := 0;
  v_stamp text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');
begin
  create temp table if not exists _set_explode_items (
    ord int,
    line_id text,
    variation_id text,
    item_code text,
    name text,
    detail text,
    quantity numeric,
    price numeric,
    note text,
    discount jsonb,
    is_bonus jsonb,
    is_discount_percent jsonb,
    is_wholesale jsonb,
    set_idx int,                               -- new component rows: which p_sets entry added them
    removed boolean not null default false
  ) on commit drop;
  truncate _set_explode_items;

  insert into _set_explode_items (ord, line_id, variation_id, item_code, name, detail, quantity, price, note,
                                  discount, is_bonus, is_discount_percent, is_wholesale)
  select
    (row_number() over (order by length(l."LineID"), l."LineID"))::int,
    l."LineID", nullif(trim(coalesce(l."VariationId", '')), ''), nullif(trim(coalesce(l."ItemCode", '')), ''),
    nullif(trim(coalesce(l."Description", '')), ''), l."Description", l."Quantity", l."Price", l."Note",
    '0'::jsonb, 'false'::jsonb, 'false'::jsonb, 'false'::jsonb
  from public."OnlineOrderLines" l
  where l."OrderID" = p_order_id;

  if not exists (select 1 from _set_explode_items) then
    raise exception 'Order % has no lines - nothing was changed.', p_order_id;
  end if;

  for v_set, v_set_idx in select e.value, e.ord::int from jsonb_array_elements(p_sets) with ordinality as e(value, ord)
  loop
    select * into v_parent from _set_explode_items
    where line_id = v_set ->> 'line_id' and not removed
    limit 1;
    if not found then
      raise exception 'SET line % is no longer on order % in Pancake - close and reopen the order, then try again.',
        coalesce(v_set ->> 'line_id', '?'), p_order_id;
    end if;

    if not public._set_package_has_lines(v_set ->> 'package_name') then
      raise exception 'Package "%" has no BOM lines.', coalesce(v_set ->> 'package_name', '');
    end if;

    -- Same display text as the POS's BuildSetLineDisplayText (Description, ItemCode, VariationId).
    v_display := coalesce(v_parent.name, v_parent.item_code, v_parent.variation_id, 'SET Line ' || v_parent.line_id);
    v_material_note := 'SET Material for ' || v_display;

    -- Old materials of this SET (from an earlier portal or POS run) - Pancake's rows only, never the
    -- component rows this call just added for another SET line with the same name.
    update _set_explode_items set removed = true
    where trim(coalesce(note, '')) = v_material_note
      and set_idx is null
      and line_id is distinct from v_parent.line_id;

    if coalesce((v_set ->> 'save_mapping')::boolean, false) then
      insert into public."OnlineOrderSetPackageMap" ("MatchType", "MatchValue", "PackageName", "SourceDescription", "UpdatedDate")
      values (
        case when v_parent.variation_id is not null then 'VariationId' else 'ItemCode' end,
        coalesce(v_parent.variation_id, v_parent.item_code),
        trim(v_set ->> 'package_name'),
        left(v_display, 255),
        now()
      )
      on conflict ("MatchType", "MatchValue") do update
        set "PackageName" = excluded."PackageName",
            "SourceDescription" = excluded."SourceDescription",
            "UpdatedDate" = now();
    end if;

    select coalesce(max(ord), 0) into v_next_ord from _set_explode_items;

    for v_mat in select * from jsonb_array_elements(coalesce(v_set -> 'materials', '[]'::jsonb))
    loop
      v_mat_qty := public.pancake_parse_decimal(v_mat ->> 'quantity');
      if v_mat_qty is null or v_mat_qty <= 0 then
        continue;
      end if;

      v_mat_code := nullif(trim(coalesce(v_mat ->> 'item_code', '')), '');
      v_mat_variation := nullif(trim(coalesce(v_mat ->> 'variation_id', '')), '');
      if v_mat_variation is null and v_mat_code is not null then
        select nullif(trim(i."VariationId"), '') into v_mat_variation
        from public."Items" i where i."Code" = v_mat_code or i."VariationId" = v_mat_code
        order by (i."Code" = v_mat_code) desc limit 1;
      end if;
      if v_mat_code is null and v_mat_variation is not null then
        select nullif(trim(i."Code"), '') into v_mat_code
        from public."Items" i where i."VariationId" = v_mat_variation limit 1;
      end if;
      v_mat_name := coalesce(nullif(trim(coalesce(v_mat ->> 'name', '')), ''), v_mat_code, v_mat_variation);

      if v_mat_variation is null then
        raise exception 'Component "%" is not linked to a Pancake product (no VariationId in Items) - fix the item or remove it from the set.',
          coalesce(v_mat_name, '?');
      end if;

      v_next_ord := v_next_ord + 1;
      v_material_count := v_material_count + 1;
      insert into _set_explode_items (ord, line_id, variation_id, item_code, name, detail, quantity, price, note,
                                      discount, is_bonus, is_discount_percent, is_wholesale, set_idx)
      values (v_next_ord, null, v_mat_variation, v_mat_code, v_mat_name, v_mat_name, v_mat_qty, 0, v_material_note,
              '0'::jsonb, 'false'::jsonb, 'false'::jsonb, 'false'::jsonb, v_set_idx);
    end loop;

    -- "SET Materials: <name> x <qty>; ..." on the SET line, replacing any earlier one, keeping the rest.
    select string_agg(g.name || ' x ' || to_char(g.qty, 'FM999,999,990'), '; ' order by g.first_ord) into v_summary
    from (
      select name, sum(quantity) as qty, min(ord) as first_ord
      from _set_explode_items
      where set_idx = v_set_idx
      group by name
    ) g;

    select string_agg(l, E'\n') into v_kept_note
    from regexp_split_to_table(coalesce(v_parent.note, ''), E'\r?\n') l
    where trim(l) <> '' and ltrim(l) not ilike 'SET Materials:%';

    if v_summary is not null then
      v_kept_note := concat_ws(E'\n', v_kept_note, 'SET Materials: ' || v_summary);
    end if;

    update _set_explode_items set note = v_kept_note
    where ord = v_parent.ord;
  end loop;

  -- Write the result back to the portal order's own lines.
  delete from public."OnlineOrderLines" l
  using _set_explode_items x
  where l."OrderID" = p_order_id and x.removed and x.line_id is not null and l."LineID" = x.line_id;

  update public."OnlineOrderLines" l
  set "Note" = nullif(x.note, ''), "SyncedAtUtc" = now()
  from _set_explode_items x
  where l."OrderID" = p_order_id and not x.removed and x.line_id is not null and l."LineID" = x.line_id
    and l."Note" is distinct from nullif(x.note, '');

  insert into public."OnlineOrderLines" (
    "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price",
    "Discount", "GrossAmount", "NetAmount", "Note", "Description", "SyncedAtUtc"
  )
  select p_order_id, 'SET-' || v_stamp || '-' || x.ord, x.item_code, x.item_code, x.variation_id, x.quantity, null, 0,
         0, 0, 0, nullif(x.note, ''), left(coalesce(x.name, x.item_code, 'SET Material'), 500), now()
  from _set_explode_items x
  where x.line_id is null and not x.removed;

  return jsonb_build_object('material_lines', v_material_count, 'resynced', true);
end;
$$;

create or replace function public.staff_save_online_order_set_materials(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_sets jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '45000'
as $$
declare
  v_url text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_set jsonb;
  v_set_idx int;
  v_mat jsonb;
  v_parent record;
  v_display text;
  v_material_note text;
  v_summary text;
  v_kept_note text;
  v_mat_qty numeric;
  v_mat_variation text;
  v_mat_code text;
  v_mat_name text;
  v_next_ord int;
  v_material_count int := 0;
  v_items jsonb;
  v_body jsonb;
  v_patch_response extensions.http_response;
  v_put_response extensions.http_response;
  v_resynced boolean := true;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_order_id is null or trim(p_order_id) = '' then
    raise exception 'Order ID is required.';
  end if;
  if p_sets is null or jsonb_typeof(p_sets) <> 'array' or jsonb_array_length(p_sets) = 0 then
    raise exception 'No SET lines were sent.';
  end if;

  -- Portal-only orders (supabase_bot_orders_portal_confirm.sql) have no Pancake order - assemble locally.
  if public._is_portal_only_online_order(p_order_id) then
    return public._save_portal_order_set_materials(trim(p_order_id), p_sets);
  end if;

  v_url := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || trim(p_order_id)
    || '?api_key=' || public._pancake_api_key() || '&page_size=1000';

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  perform extensions.http_set_curlopt('CURLOPT_USERAGENT', 'RSPetStopPortal/1.0');

  -- Pancake's current copy of the order is the base - the update replaces ALL items, so a failed read
  -- must stop here rather than push a partial list.
  v_get_response := extensions.http_get(v_url);
  if v_get_response.status < 200 or v_get_response.status >= 300 then
    raise exception 'Could not read order % from Pancake (HTTP %). Please try again.', p_order_id, v_get_response.status;
  end if;
  v_get_body := v_get_response.content::jsonb;
  v_order_obj := case
    when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
    when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
    else v_get_body
  end;
  if jsonb_typeof(v_order_obj -> 'items') <> 'array' or jsonb_array_length(v_order_obj -> 'items') = 0 then
    raise exception 'Pancake returned no items for order % - nothing was changed.', p_order_id;
  end if;
  if jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then
    v_bank_payments := v_order_obj -> 'bank_payments';
  end if;

  create temp table if not exists _set_explode_items (
    ord int,
    line_id text,
    variation_id text,
    item_code text,
    name text,
    detail text,
    quantity numeric,
    price numeric,
    note text,
    discount jsonb,
    is_bonus jsonb,
    is_discount_percent jsonb,
    is_wholesale jsonb,
    set_idx int,                               -- new component rows: which p_sets entry added them
    removed boolean not null default false
  ) on commit drop;
  truncate _set_explode_items;

  insert into _set_explode_items (ord, line_id, variation_id, item_code, name, detail, quantity, price, note,
                                  discount, is_bonus, is_discount_percent, is_wholesale)
  select
    e.ord::int,
    nullif(coalesce(it ->> 'line_id', it ->> 'id', it ->> 'order_line_id', it ->> 'order_item_id', it ->> 'item_id'), ''),
    nullif(trim(coalesce(it -> 'variation_info' ->> 'variation_id', it ->> 'variation_id', it ->> 'variationId', '')), ''),
    nullif(trim(coalesce(it -> 'variation_info' ->> 'product_display_id', it ->> 'product_display_id',
                         it -> 'variation_info' ->> 'display_id', '')), ''),
    nullif(trim(coalesce(it -> 'variation_info' ->> 'name', it ->> 'name', '')), ''),
    coalesce(it -> 'variation_info' ->> 'detail', it -> 'variation_info' ->> 'name', it ->> 'name'),
    public.pancake_parse_decimal(it ->> 'quantity'),
    public.pancake_parse_decimal(coalesce(it -> 'variation_info' ->> 'retail_price', it ->> 'retail_price')),
    it ->> 'note',
    case when jsonb_typeof(it -> 'discount_each_product') = 'number' then it -> 'discount_each_product' else '0'::jsonb end,
    case when jsonb_typeof(it -> 'is_bonus_product') = 'boolean' then it -> 'is_bonus_product' else 'false'::jsonb end,
    case when jsonb_typeof(it -> 'is_discount_percent') = 'boolean' then it -> 'is_discount_percent' else 'false'::jsonb end,
    case when jsonb_typeof(it -> 'is_wholesale') = 'boolean' then it -> 'is_wholesale' else 'false'::jsonb end
  from jsonb_array_elements(v_order_obj -> 'items') with ordinality as e(it, ord);

  for v_set, v_set_idx in select e.value, e.ord::int from jsonb_array_elements(p_sets) with ordinality as e(value, ord)
  loop
    select * into v_parent from _set_explode_items
    where line_id = v_set ->> 'line_id' and not removed
    limit 1;
    if not found then
      raise exception 'SET line % is no longer on order % in Pancake - close and reopen the order, then try again.',
        coalesce(v_set ->> 'line_id', '?'), p_order_id;
    end if;

    if not public._set_package_has_lines(v_set ->> 'package_name') then
      raise exception 'Package "%" has no BOM lines.', coalesce(v_set ->> 'package_name', '');
    end if;

    -- Same display text as the POS's BuildSetLineDisplayText (Description, ItemCode, VariationId).
    v_display := coalesce(v_parent.name, v_parent.item_code, v_parent.variation_id, 'SET Line ' || v_parent.line_id);
    v_material_note := 'SET Material for ' || v_display;

    -- Old materials of this SET (from an earlier portal or POS run) - Pancake's rows only, never the
    -- component rows this call just added for another SET line with the same name.
    update _set_explode_items set removed = true
    where trim(coalesce(note, '')) = v_material_note
      and set_idx is null
      and line_id is distinct from v_parent.line_id;

    if coalesce((v_set ->> 'save_mapping')::boolean, false) then
      insert into public."OnlineOrderSetPackageMap" ("MatchType", "MatchValue", "PackageName", "SourceDescription", "UpdatedDate")
      values (
        case when v_parent.variation_id is not null then 'VariationId' else 'ItemCode' end,
        coalesce(v_parent.variation_id, v_parent.item_code),
        trim(v_set ->> 'package_name'),
        left(v_display, 255),
        now()
      )
      on conflict ("MatchType", "MatchValue") do update
        set "PackageName" = excluded."PackageName",
            "SourceDescription" = excluded."SourceDescription",
            "UpdatedDate" = now();
    end if;

    select coalesce(max(ord), 0) into v_next_ord from _set_explode_items;

    for v_mat in select * from jsonb_array_elements(coalesce(v_set -> 'materials', '[]'::jsonb))
    loop
      v_mat_qty := public.pancake_parse_decimal(v_mat ->> 'quantity');
      if v_mat_qty is null or v_mat_qty <= 0 then
        continue;
      end if;

      v_mat_code := nullif(trim(coalesce(v_mat ->> 'item_code', '')), '');
      v_mat_variation := nullif(trim(coalesce(v_mat ->> 'variation_id', '')), '');
      if v_mat_variation is null and v_mat_code is not null then
        select nullif(trim(i."VariationId"), '') into v_mat_variation
        from public."Items" i where i."Code" = v_mat_code or i."VariationId" = v_mat_code
        order by (i."Code" = v_mat_code) desc limit 1;
      end if;
      if v_mat_code is null and v_mat_variation is not null then
        select nullif(trim(i."Code"), '') into v_mat_code
        from public."Items" i where i."VariationId" = v_mat_variation limit 1;
      end if;
      v_mat_name := coalesce(nullif(trim(coalesce(v_mat ->> 'name', '')), ''), v_mat_code, v_mat_variation);

      if v_mat_variation is null then
        raise exception 'Component "%" is not linked to a Pancake product (no VariationId in Items) - fix the item or remove it from the set.',
          coalesce(v_mat_name, '?');
      end if;

      v_next_ord := v_next_ord + 1;
      v_material_count := v_material_count + 1;
      insert into _set_explode_items (ord, line_id, variation_id, item_code, name, detail, quantity, price, note,
                                      discount, is_bonus, is_discount_percent, is_wholesale, set_idx)
      values (v_next_ord, null, v_mat_variation, v_mat_code, v_mat_name, v_mat_name, v_mat_qty, 0, v_material_note,
              '0'::jsonb, 'false'::jsonb, 'false'::jsonb, 'false'::jsonb, v_set_idx);
    end loop;

    -- "SET Materials: <name> x <qty>; ..." on the SET line, replacing any earlier one, keeping the rest.
    select string_agg(g.name || ' x ' || to_char(g.qty, 'FM999,999,990'), '; ' order by g.first_ord) into v_summary
    from (
      select name, sum(quantity) as qty, min(ord) as first_ord
      from _set_explode_items
      where set_idx = v_set_idx
      group by name
    ) g;

    select string_agg(l, E'\n') into v_kept_note
    from regexp_split_to_table(coalesce(v_parent.note, ''), E'\r?\n') l
    where trim(l) <> '' and ltrim(l) not ilike 'SET Materials:%';

    if v_summary is not null then
      v_kept_note := concat_ws(E'\n', v_kept_note, 'SET Materials: ' || v_summary);
    end if;

    update _set_explode_items set note = v_kept_note
    where ord = v_parent.ord;
  end loop;

  select jsonb_agg(jsonb_build_object(
    'line_id', line_id,
    'discount_each_product', discount,
    'is_bonus_product', is_bonus,
    'is_discount_percent', is_discount_percent,
    'is_wholesale', is_wholesale,
    'one_time_product', variation_id is null,
    'quantity', case when coalesce(abs(quantity), 0) = 0 then 1 else abs(quantity) end,
    'variation_id', variation_id,
    'note', nullif(note, ''),
    'variation_info', jsonb_build_object(
      'detail', coalesce(detail, name),
      'fields', null,
      'display_id', item_code,
      'name', coalesce(name, item_code, 'Online Item'),
      'product_display_id', item_code,
      'retail_price', coalesce(price, 0),
      'weight', 100
    )
  ) order by ord)
  into v_items
  from _set_explode_items
  where not removed;

  v_body := jsonb_build_object('items', v_items);

  v_patch_response := extensions.http((
    'PATCH', v_url,
    array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
    'application/json', v_body::text
  )::extensions.http_request);

  if v_patch_response.status = 404 or v_patch_response.status = 405 then
    v_put_response := extensions.http((
      'PUT', v_url,
      array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
      'application/json', v_body::text
    )::extensions.http_request);
    if v_put_response.status < 200 or v_put_response.status >= 300 then
      raise exception 'Pancake rejected the items update (PATCH %: % / PUT %: %)',
        v_patch_response.status, left(v_patch_response.content, 300),
        v_put_response.status, left(v_put_response.content, 300);
    end if;
  elsif v_patch_response.status < 200 or v_patch_response.status >= 300 then
    raise exception 'Pancake rejected the items update (HTTP %): %', v_patch_response.status, left(v_patch_response.content, 300);
  end if;

  -- Pancake wipes bank_payments on any PATCH unless re-sent (same as the POS and the other PATCHes).
  if v_bank_payments is not null then
    begin
      perform extensions.http((
        'PATCH', v_url,
        array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
        'application/json', jsonb_build_object('bank_payments', v_bank_payments)::text
      )::extensions.http_request);
    exception when others then
      null;
    end;
  end if;

  -- Pull the order back so OnlineOrderLines has Pancake's own line IDs for the new components.
  begin
    perform public._sync_online_order_detail(trim(p_order_id));
  exception when others then
    v_resynced := false;
  end;

  return jsonb_build_object('material_lines', v_material_count, 'resynced', v_resynced);
end;
$$;

grant execute on function public.staff_save_online_order_set_materials(text, text, text, jsonb) to anon;
