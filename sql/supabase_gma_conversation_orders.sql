-- Lets staff create a real Automated Order (see supabase_automated_orders_tables.sql) directly
-- from a GMA conversation (docs/gma-conversations.html), deliberately linked to that exact
-- conversation - closing the gap flagged when the conversation panel was first built: GMA runs on
-- its own separate Facebook Page from the Pancake-connected one, so there was no reliable id to
-- join a conversation to an order. This gives every order created here its own linkage columns
-- ("GmaPsid"/"GmaPageId") set at creation time by OUR OWN code, rather than trying to reuse
-- AutomatedOrders."Psid" (which is specifically the Pancake-page psid used to build Pancake's own
-- conversation_id in _push_automated_order_to_pancake below - stamping a GMA psid into that column
-- would silently send Pancake a garbage/foreign conversation_id). "Psid" is left null here on
-- purpose, which _push_automated_order_to_pancake already treats as "no conversation to attach in
-- Pancake" - a safe, already-supported path.
--
-- Also adds a lightweight payments ledger (AutomatedOrderPayments) - AutomatedOrders/Pancake's own
-- order-creation API has no payment/amount-collected concept at all (COD-style; Pancake tracks
-- collection itself once the order ships), so there was nowhere to record that a customer already
-- paid (e.g. sent a GCash screenshot) while chatting. Purely a portal-side record, not synced
-- anywhere else.
--
-- Per follow-up request, staff want this visible on the ACTUAL Online Orders list (docs/online-
-- orders.html - the real, Pancake-synced OnlineOrders table), not just on the separate Automated
-- Orders admin page - a "GMA Page" badge next to any order that started life here. OnlineOrders is
-- a one-way Pancake sync mirror though (see supabase_orders_sync_tables.sql's header comment) -
-- nothing is ever inserted into it directly - so the flag has to be computed by matching a synced
-- OnlineOrders row back to the AutomatedOrders row that originated it. AutomatedOrders."PancakeOrderId"
-- (Pancake's own short internal id, e.g. "74398") is NOT what ends up in OnlineOrders."OrderID" -
-- the list-sync (supabase_pancake_manual_sync.sql) prefers Pancake's receipt_no field for that
-- column instead. So "PancakeReceiptNo" below captures that SAME field, straight off the
-- order-creation response, giving admin_list_online_orders a real, exact join key
-- (PancakeReceiptNo = OnlineOrders.OrderID) instead of a mismatched/guessed one.

alter table public."AutomatedOrders" add column if not exists "GmaPsid" varchar(255);
alter table public."AutomatedOrders" add column if not exists "GmaPageId" varchar(50);
alter table public."AutomatedOrders" add column if not exists "PancakeReceiptNo" varchar(100);

comment on column public."AutomatedOrders"."GmaPsid" is 'Facebook PSID of the ChatbotConversations row (GMA''s own separate Facebook Page) this order was created from, if any - set only by admin_create_gma_conversation_order. Unrelated to "Psid" above, which is the Pancake-page psid.';
comment on column public."AutomatedOrders"."GmaPageId" is 'PageId of the ChatbotConversations row this order was created from, alongside GmaPsid.';
comment on column public."AutomatedOrders"."PancakeReceiptNo" is 'Pancake''s receipt_no for this order (from the order-creation response) - the same field supabase_pancake_manual_sync.sql prefers for OnlineOrders."OrderID", so this is what lets admin_list_online_orders match a synced order back to this row (e.g. for the "GMA Page" flag).';

create index if not exists "IX_AutomatedOrders_GmaPsid" on public."AutomatedOrders" ("GmaPsid") where "GmaPsid" is not null;
create index if not exists "IX_AutomatedOrders_PancakeReceiptNo" on public."AutomatedOrders" ("PancakeReceiptNo") where "PancakeReceiptNo" is not null;

-- ---------------------------------------------------------------------------
-- _push_automated_order_to_pancake: redefined (same body as supabase_automated_orders_tables.sql,
-- used by submit_automated_order/admin_retry_automated_order_pancake_push AND
-- admin_create_gma_conversation_order below) purely to also capture receipt_no off the
-- order-creation response, alongside the id/order_link it already captured. Everything else here
-- is unchanged from the original.
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
          'note', l."ItemName",
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

create table if not exists public."AutomatedOrderPayments" (
    "PaymentId" bigint generated always as identity primary key,
    "OrderNo" varchar(50) not null references public."AutomatedOrders"("OrderNo") on delete cascade,
    "Amount" numeric(18, 4) not null,
    "Method" varchar(30) not null default 'Cash',
    "Reference" varchar(200),
    "RecordedBy" varchar(100),
    "RecordedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_AutomatedOrderPayments_OrderNo" on public."AutomatedOrderPayments" ("OrderNo");

alter table public."AutomatedOrderPayments" enable row level security;
revoke all on public."AutomatedOrderPayments" from anon, authenticated;

comment on table public."AutomatedOrderPayments" is 'Manual payment log for an AutomatedOrders row (e.g. a GCash payment a customer sent while chatting) - portal-only record, not sent to Pancake.';

-- ---------------------------------------------------------------------------
-- admin_create_gma_conversation_order: same validation/insert/Pancake-push shape as
-- submit_automated_order (supabase_automated_orders_tables.sql), just admin-gated (matches the
-- rest of this page's RPCs, all is_admin_authorized/super-user only) and stamping GmaPsid/GmaPageId
-- instead of accepting a Pancake Psid.
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
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price")
    values
      (v_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price);

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
-- admin_list_automated_orders_by_gma_conversation: real, exact-match linkage (unlike the
-- name/phone manual search the conversation panel fell back to before this existed) - only ever
-- returns orders that were actually created from this specific conversation.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_list_automated_orders_by_gma_conversation(text, text, text, text);

create or replace function public.admin_list_automated_orders_by_gma_conversation(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_page_id text
)
returns table(
  order_no text,
  customer_name text,
  customer_phone text,
  fulfillment_type text,
  status text,
  estimated_total numeric,
  amount_paid numeric,
  balance numeric,
  pancake_order_id text,
  pancake_order_link text,
  pancake_sync_status text,
  created_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;

  return query
    select
      o."OrderNo"::text,
      o."CustomerName"::text,
      o."CustomerPhone"::text,
      o."FulfillmentType"::text,
      o."Status"::text,
      o."EstimatedTotal",
      coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"), 0)::numeric,
      (o."EstimatedTotal" - coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"), 0))::numeric,
      o."PancakeOrderId"::text,
      o."PancakeOrderLink"::text,
      o."PancakeSyncStatus"::text,
      o."CreatedAtUtc"
    from public."AutomatedOrders" o
    where o."GmaPsid" = trim(p_psid)
      and (p_page_id is null or trim(p_page_id) = '' or o."GmaPageId" = trim(p_page_id))
    order by o."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_automated_orders_by_gma_conversation(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_add_automated_order_payment / admin_list_automated_order_payments: the manual payments
-- ledger. Amount can be negative (e.g. a refund/correction) - deliberately not constrained to > 0,
-- since staff need to be able to back out a wrongly-logged payment without deleting history.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_add_automated_order_payment(text, text, text, numeric, text, text);

create or replace function public.admin_add_automated_order_payment(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_amount numeric,
  p_method text,
  p_reference text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_order_no is null or trim(p_order_no) = '' then
    raise exception 'OrderNo is required.';
  end if;
  if p_amount is null or p_amount = 0 then
    raise exception 'Amount is required.';
  end if;
  if not exists (select 1 from public."AutomatedOrders" where "OrderNo" = p_order_no) then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;

  insert into public."AutomatedOrderPayments" ("OrderNo", "Amount", "Method", "Reference", "RecordedBy")
  values (p_order_no, p_amount, coalesce(nullif(trim(p_method), ''), 'Cash'), nullif(trim(coalesce(p_reference, '')), ''), p_admin_username);
end;
$$;

grant execute on function public.admin_add_automated_order_payment(text, text, text, numeric, text, text) to anon;

drop function if exists public.admin_list_automated_order_payments(text, text, text);

create or replace function public.admin_list_automated_order_payments(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(payment_id bigint, amount numeric, method text, reference text, recorded_by text, recorded_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select p."PaymentId", p."Amount", p."Method"::text, p."Reference"::text, p."RecordedBy"::text, p."RecordedAtUtc"
    from public."AutomatedOrderPayments" p
    where p."OrderNo" = p_order_no
    order by p."RecordedAtUtc" asc;
end;
$$;

grant execute on function public.admin_list_automated_order_payments(text, text, text) to anon;
