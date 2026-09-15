-- Per direct follow-up request: staff building an order from a GMA conversation (the Create Order
-- tab's product table, docs/gma-conversations.html) want to attach a free-text note to an
-- individual line item (e.g. "customer wants black trim" on a catalog product) that actually syncs
-- to Pancake and prints there, the same way a line's note already does today.
--
-- AutomatedOrderLines never had a genuinely separate per-line note before this - the existing
-- 'note'/'note_product' fields sent to Pancake (_push_automated_order_to_pancake, below) are just
-- l."ItemName" duplicated, and the only staff-editable notes field anywhere in this flow is
-- AutomatedOrders."Notes" (order-level, appended to the top-level Pancake order note, not any one
-- line). This adds a real "Notes" column to AutomatedOrderLines, lets admin_create_gma_conversation_
-- order accept one per line (p_lines[].note), and sends it as that line's Pancake 'note' field
-- verbatim - exactly what staff typed in the popup, no item-name prefix or other modification, per
-- direct instruction (note_product carries the plain item name instead, so it's not lost).

alter table public."AutomatedOrderLines" add column if not exists "Notes" varchar(500);

comment on column public."AutomatedOrderLines"."Notes" is 'Optional free-text note staff attached to this specific line when creating the order from a GMA conversation (docs/gma-conversations.html Create Order tab) - sent verbatim as this line''s Pancake ''note'' field (_push_automated_order_to_pancake) so it syncs/prints per-item exactly as typed, distinct from the plain item name in ''note_product''. Null for lines created any other way (e.g. submit_automated_order), which never set this.';

-- ---------------------------------------------------------------------------
-- admin_list_automated_order_lines: redefined to also return the new Notes column, so the
-- Automated Orders admin page's order detail modal (docs/automated-orders.html, modalLinesBody in
-- js/automatedOrders.js) can show the actual per-product note alongside each item.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_list_automated_order_lines(text, text, text);

create or replace function public.admin_list_automated_order_lines(p_admin_username text, p_admin_password text, p_order_no text)
returns table(entry_no bigint, category_code text, item_code text, item_name text, quantity int, price numeric, notes text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."EntryNo", l."CategoryCode"::text, l."ItemCode"::text, l."ItemName"::text, l."Quantity", l."Price", l."Notes"::text
    from public."AutomatedOrderLines" l
    where l."OrderNo" = p_order_no
    order by l."EntryNo";
end;
$$;

grant execute on function public.admin_list_automated_order_lines(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_create_gma_conversation_order: redefined to also read/store p_lines[].note.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb);

create or replace function public.admin_create_gma_conversation_order(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_page_id text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_lines jsonb
)
returns table(order_no text, pancake_order_id text, pancake_sync_status text, pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
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

  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');

  insert into public."AutomatedOrders"
    ("OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status", "EstimatedTotal", "Location", "GmaPsid", "GmaPageId", "UpdatedBy")
  values
    (v_order_no, trim(p_customer_name), trim(p_customer_phone), nullif(trim(coalesce(p_customer_email, '')), ''),
     v_fulfillment, case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
     nullif(trim(coalesce(p_notes, '')), ''), 'New', 0, v_location, trim(p_psid), nullif(trim(coalesce(p_page_id, '')), ''), p_admin_username);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);
    v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes")
    values
      (v_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price,
       nullif(trim(coalesce(v_line->>'note', '')), ''));

    v_total := v_total + (v_qty * v_price);
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = v_order_no;

  perform public._push_automated_order_to_pancake(v_order_no);

  return query
    select o."OrderNo"::text, o."PancakeOrderId"::text, o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = v_order_no;
end;
$$;

grant execute on function public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb) to anon;

-- ---------------------------------------------------------------------------
-- _push_automated_order_to_pancake: redefined once more (same body as supabase_gma_conversation_
-- orders.sql's version - which itself only added receipt_no capture over the original in
-- supabase_automated_orders_tables.sql), changing ONLY the per-line 'note' field to send the new
-- Notes column verbatim (coalesced to '' when the staff left it blank - never null, and never
-- combined with the item name). Everything else below (PancakeLastPayload, the id/receipt_no
-- fallback chains, the retry/error-logging behavior) is copied verbatim from that live version - not
-- reconstructed from memory - since this is a shared function other order-creation paths depend on
-- too. note_product is left as the plain item name on purpose - see file header.
-- ---------------------------------------------------------------------------

create or replace function public._push_automated_order_to_pancake(p_order_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_page_id text := '195716644410829';
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_location text;
  v_warehouse_id text;
  v_line_count int;
  v_items_json jsonb;
  v_matched_count int;
  v_customer_id text;
  v_conversation_id text;
  v_shipping_json jsonb;
  v_payload jsonb;
  v_url text;
  v_response extensions.http_response;
  v_pancake_body jsonb;
  v_pancake_order_id text;
  v_pancake_order_link text;
  v_pancake_receipt_no text;
  v_lines_note text;
  v_attempt int;
  v_max_attempts constant int := 3;
begin
  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;

  update public."AutomatedOrders" set "PancakeLastAttemptAtUtc" = now() where "OrderNo" = p_order_no;

  for v_attempt in 1..v_max_attempts loop
  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

    v_location := coalesce(nullif(trim(v_order."Location"), ''), 'Amaya');

    select "ID" into v_warehouse_id
    from public."Warehouses"
    where "Name" ilike '%' || v_location || '%'
    order by "Name"
    limit 1;

    if v_warehouse_id is null then
      raise exception 'No Warehouses row matches location "%".', v_location;
    end if;

    select count(*) into v_line_count from public."AutomatedOrderLines" where "OrderNo" = p_order_no;

    select string_agg(l."ItemName" || ' x' || l."Quantity" || ' @ ' || l."Price", E'\n' order by l."EntryNo")
    into v_lines_note
    from public."AutomatedOrderLines" l
    where l."OrderNo" = p_order_no;

    select
      jsonb_agg(
        jsonb_build_object(
          'variation_id', i."VariationId",
          'product_id', i."ProductId",
          'quantity', l."Quantity",
          'note', coalesce(l."Notes", ''),
          'note_product', l."ItemName",
          'variation_info', jsonb_build_object(
            'id', i."VariationId",
            'product_id', i."ProductId",
            'name', l."ItemName",
            'retail_price', round(l."Price")::int
          )
        )
      ),
      count(*)
    into v_items_json, v_matched_count
    from public."AutomatedOrderLines" l
    join public."Items" i
      on i."Code" = coalesce(nullif(l."ItemCode", ''), nullif(l."CategoryCode", ''))
      or (l."ItemCode" is null and i."Name" = nullif(l."CategoryCode", ''))
    where l."OrderNo" = p_order_no
      and (i."VariationId" is not null or i."ProductId" is not null);

    if v_matched_count is null or v_matched_count = 0 then
      raise exception 'None of this order''s lines matched a known Pancake product (Items.VariationId/ProductId) - nothing to push.';
    end if;
    if v_matched_count < v_line_count then
      raise exception '% of % order lines matched a known Pancake product - refusing a partial push.', v_matched_count, v_line_count;
    end if;

    if v_order."Psid" is not null then
      v_conversation_id := v_page_id || '_' || v_order."Psid";

      select "CustomerID" into v_customer_id
      from public."OnlineCustomers"
      where "FbID" = v_order."Psid" or "FbID" = v_conversation_id
      limit 1;
    end if;

    v_shipping_json := case when v_order."FulfillmentType" = 'Delivery' then
      jsonb_build_object(
        'address', v_order."DeliveryAddress",
        'full_address', v_order."DeliveryAddress",
        'full_name', v_order."CustomerName",
        'phone_number', v_order."CustomerPhone"
      )
    else null end;

    v_payload := jsonb_build_object(
      'shop_id', v_shop_id,
      'warehouse_id', v_warehouse_id,
      'bill_full_name', v_order."CustomerName",
      'bill_phone_number', v_order."CustomerPhone",
      'bill_email', v_order."CustomerEmail",
      'page_id', v_page_id,
      'items', v_items_json,
      'note', 'Web order ' || p_order_no
        || coalesce(E'\n' || v_lines_note, '')
        || coalesce(' | Customer note: ' || nullif(trim(v_order."Notes"), ''), ''),
      'is_free_shipping', false,
      'shipping_fee', 0,
      'status', 0
    )
      || case when v_customer_id is not null then jsonb_build_object('customer_id', v_customer_id) else '{}'::jsonb end
      || case when v_conversation_id is not null then jsonb_build_object('conversation_id', v_conversation_id) else '{}'::jsonb end
      || case when v_shipping_json is not null then jsonb_build_object('shipping_address', v_shipping_json) else '{}'::jsonb end;

    v_url := v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key;

    perform extensions.http_set_curlopt('CURLOPT_USERAGENT', 'RSPetStopPortal/1.0');

    select * into v_response from extensions.http((
      'POST',
      v_url,
      array[
        extensions.http_header('Accept', 'application/json'),
        extensions.http_header('Expect', '')
      ],
      'application/json',
      v_payload::text
    )::extensions.http_request);

    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake order creation failed (HTTP %): % | Headers: %',
        v_response.status,
        left(v_response.content, 300),
        left(coalesce((select string_agg(h.field || '=' || h.value, ' | ') from unnest(v_response.headers) h), '(none)'), 400);
    end if;

    v_pancake_body := v_response.content::jsonb;
    v_pancake_order_id := coalesce(
      nullif(v_pancake_body ->> 'id', ''),
      nullif(v_pancake_body -> 'data' ->> 'id', ''),
      nullif(v_pancake_body ->> 'order_id', '')
    );
    v_pancake_order_link := coalesce(
      nullif(v_pancake_body ->> 'order_link', ''),
      nullif(v_pancake_body -> 'data' ->> 'order_link', '')
    );
    -- Same field name priority supabase_pancake_manual_sync.sql uses to populate OnlineOrders.
    -- "OrderID" (receipt_no first, falling back to id/order_number/number) - matching that
    -- priority here is what makes PancakeReceiptNo line up with OnlineOrders."OrderID" once this
    -- order syncs, rather than needing a second guess.
    v_pancake_receipt_no := coalesce(
      nullif(v_pancake_body ->> 'receipt_no', ''),
      nullif(v_pancake_body -> 'data' ->> 'receipt_no', ''),
      nullif(v_pancake_body ->> 'receiptNo', ''),
      nullif(v_pancake_body -> 'data' ->> 'receiptNo', ''),
      nullif(v_pancake_body ->> 'order_number', ''),
      nullif(v_pancake_body -> 'data' ->> 'order_number', ''),
      v_pancake_order_id
    );

    update public."AutomatedOrders"
    set "PancakeOrderId" = v_pancake_order_id,
        "PancakeOrderLink" = v_pancake_order_link,
        "PancakeReceiptNo" = v_pancake_receipt_no,
        "PancakeSyncStatus" = 'Synced',
        "PancakeSyncError" = null,
        "PancakeLastPayload" = v_payload::text
    where "OrderNo" = p_order_no;

    exit;
  exception when others then
    update public."AutomatedOrders"
    set "PancakeSyncStatus" = 'Failed',
        "PancakeSyncError" = left(sqlerrm, 1000)
          || case when v_attempt < v_max_attempts then format(' (attempt %s/%s, retrying...)', v_attempt, v_max_attempts) else format(' (attempt %s/%s)', v_attempt, v_max_attempts) end,
        "PancakeLastPayload" = v_payload::text
    where "OrderNo" = p_order_no;

    if v_attempt < v_max_attempts then
      perform pg_sleep(1.5);
    end if;
  end;
  end loop;
end;
$$;
