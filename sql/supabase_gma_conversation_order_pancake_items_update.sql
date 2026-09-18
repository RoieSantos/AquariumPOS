-- Per direct follow-up ("hey can we update pancake too???" after seeing admin_update_automated_
-- order's original 'Stale' fallback): turns out Pancake's order API DOES support updating an
-- already-created order's line items - just not via _push_automated_order_to_pancake's own POST
-- .../orders endpoint (that always CREATES a new order, which is why editing a 'Synced' order was
-- never allowed to call it again - see supabase_gma_conversation_order_edit.sql's own header
-- comment). The proof is in the desktop POS app's own working code: OnlinefunctionsEvents.cs's
-- SyncOnlineOrderItemsFromLocalLinesAsync PATCHes (falling back to PUT on 404/405)
-- .../shops/{shopId}/orders/{orderId}?api_key=...&page_size=1000 with a body of
-- { items: [...] } to replace an existing order's line items wholesale - the exact same endpoint
-- admin_add_automated_order_payment/admin_update_online_order_status already PATCH for
-- bank_payments/status. This mirrors that proven call as closely as possible: same URL shape, same
-- GET-snapshot/PATCH-items/PATCH-restore-bank_payments dance (Pancake silently wipes bank_payments
-- on any PATCH unless it's re-sent - same reason the other two PATCHes already do this), same
-- PATCH-then-PUT-on-404/405 fallback, and the SAME items field shape
-- (line_id/discount_each_product/is_bonus_product/is_discount_percent/is_wholesale/
-- one_time_product/quantity/variation_id/note/variation_info{detail/fields/display_id/name/
-- product_display_id/retail_price/weight}) copied from BuildOnlineOrderItemsPayloadFromLocalLines,
-- not the differently-shaped 'items' the CREATE push builds (_push_automated_order_to_pancake) -
-- those are two different Pancake payload contracts (create vs. update) and only the update shape
-- above has a real, working precedent to copy from.
--
-- Matching stays exactly as conservative as _push_automated_order_to_pancake's own creation path:
-- every line must resolve to a known Items."VariationId"/"ProductId" (same join/predicate) or the
-- whole update is refused (never a partial push) - one_time_product is always sent as false here,
-- unlike the desktop's own fallback for an unmatched online-order line, since introducing that
-- would be a bigger behavior change than "also update Pancake" asked for.
--
-- admin_update_automated_order is redefined once more so a 'Synced' order's edit now actually
-- attempts this live update instead of immediately giving up and marking the order 'Stale' - it
-- only falls back to 'Stale' (with the real Pancake error message) if this call itself fails, so a
-- network hiccup or a payload Pancake rejects never leaves the local record silently wrong.

create or replace function public._update_automated_order_items_in_pancake(p_order_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_order_url text;
  v_line_count int;
  v_matched_count int;
  v_items_json jsonb;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_body jsonb;
  v_patch_response extensions.http_response;
  v_put_response extensions.http_response;
begin
  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;
  if v_order."PancakeReceiptNo" is null then
    raise exception 'This order has no Pancake receipt number yet - it was never actually synced.';
  end if;

  select count(*) into v_line_count from public."AutomatedOrderLines" where "OrderNo" = p_order_no;

  select
    jsonb_agg(
      jsonb_build_object(
        'line_id', null,
        'discount_each_product', 0,
        'is_bonus_product', false,
        'is_discount_percent', false,
        'is_wholesale', false,
        'one_time_product', false,
        'quantity', l."Quantity",
        'variation_id', coalesce(nullif(l."VariationId", ''), i."VariationId"),
        'note', coalesce(l."Notes", ''),
        'variation_info', jsonb_build_object(
          'detail', l."ItemName",
          'fields', null,
          'display_id', l."ItemCode",
          'name', l."ItemName",
          'product_display_id', l."ItemCode",
          'retail_price', round(l."Price")::int,
          'weight', 100
        )
      )
      order by l."EntryNo"
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
    raise exception 'None of this order''s lines matched a known Pancake product - refusing to update items in Pancake.';
  end if;
  if v_matched_count < v_line_count then
    raise exception '% of % order lines matched a known Pancake product - refusing a partial items update.', v_matched_count, v_line_count;
  end if;

  v_order_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order."PancakeReceiptNo" || '?api_key=' || v_api_key || '&page_size=1000';

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  perform extensions.http_set_curlopt('CURLOPT_USERAGENT', 'RSPetStopPortal/1.0');

  -- Snapshot bank_payments first - Pancake silently wipes it on any PATCH to this order unless it's
  -- re-sent, same reason admin_add_automated_order_payment/admin_update_online_order_status already
  -- do this GET-before/restore-after dance. Best-effort: a failed GET just skips the restore rather
  -- than blocking the items update itself.
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
    v_bank_payments := null;
  end;

  v_body := jsonb_build_object('items', v_items_json);

  select * into v_patch_response from extensions.http((
    'PATCH',
    v_order_url,
    array[
      extensions.http_header('Accept', 'application/json'),
      extensions.http_header('Expect', '')
    ],
    'application/json',
    v_body::text
  )::extensions.http_request);

  if v_patch_response.status >= 200 and v_patch_response.status < 300 then
    -- Succeeded via PATCH - nothing more to do here.
    null;
  elsif v_patch_response.status = 404 or v_patch_response.status = 405 then
    -- Same PATCH-then-PUT-on-404/405 fallback SyncOnlineOrderItemsFromLocalLinesAsync uses.
    select * into v_put_response from extensions.http((
      'PUT',
      v_order_url,
      array[
        extensions.http_header('Accept', 'application/json'),
        extensions.http_header('Expect', '')
      ],
      'application/json',
      v_body::text
    )::extensions.http_request);

    if v_put_response.status < 200 or v_put_response.status >= 300 then
      raise exception 'Pancake rejected the items update (PATCH %: % / PUT %: %)',
        v_patch_response.status, left(v_patch_response.content, 300),
        v_put_response.status, left(v_put_response.content, 300);
    end if;
  else
    raise exception 'Pancake rejected the items update (HTTP %): %', v_patch_response.status, left(v_patch_response.content, 300);
  end if;

  if v_bank_payments is not null then
    -- Best-effort restore, same as the other two PATCHes - never fails the items update itself.
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

  update public."AutomatedOrders"
  set "PancakeSyncStatus" = 'Synced',
      "PancakeSyncError" = null,
      "PancakeLastPayload" = v_body::text,
      "PancakeLastAttemptAtUtc" = now()
  where "OrderNo" = p_order_no;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_update_automated_order: redefined once more - the 'Synced' branch now actually attempts
-- _update_automated_order_items_in_pancake above instead of immediately giving up. Everything else
-- (validation, header update, line replace, EstimatedTotal recalc, Pending/Failed/Stale branch)
-- copied verbatim from supabase_gma_conversation_order_edit.sql.
-- ---------------------------------------------------------------------------

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
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
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
  else
    perform public._push_automated_order_to_pancake(p_order_no);
  end if;

  return query
    select o."OrderNo"::text, o."EstimatedTotal", o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = p_order_no;
end;
$$;

grant execute on function public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb) to anon;
