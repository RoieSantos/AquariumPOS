-- "Automated Orders": customer-submitted order requests from the public, no-login order wizard
-- (docs/order-now.html / js/orderNow.js). A customer picks a category (Aquarium/Stand/Filtration/
-- Sump/Fish/etc, sourced live from Items/Categories), adds items + quantities to a cart, enters
-- contact + pickup/delivery info, and submits - landing here as its own table (per direct request:
-- "I want a separate table, Automated Orders"), NOT into OnlineOrders (that table is a one-way
-- Pancake sync mirror - see supabase_orders_sync_tables.sql - not something a customer wizard
-- should write into).
--
-- Unlike supabase_allow_anon_order_sync.sql's emergency stop-gap (full anon select/insert/update
-- on Pancake-order tables, explicitly flagged there as a workaround not a design), this is a
-- narrow, intentional public-insert surface: anon gets ONLY an insert-only, validating RPC
-- (submit_automated_order) plus two read-only catalog lookups (public_list_order_categories/
-- public_list_order_items) that expose nothing but active items' name/price/image. Direct table
-- access stays fully revoked from anon/authenticated; staff read/update goes through the usual
-- is_staff_authorized-gated admin_* RPCs (same trust model as Online Orders/Delivery - open to any
-- active staff login, not just super users, so requests get followed up on quickly).

create table if not exists public."AutomatedOrders" (
    "OrderNo" varchar(50) primary key,
    "CustomerName" varchar(200) not null,
    "CustomerPhone" varchar(50) not null,
    "CustomerEmail" varchar(200),
    "FulfillmentType" varchar(20) not null default 'Pickup',
    "DeliveryAddress" varchar(500),
    "Notes" varchar(1000),
    "Status" varchar(30) not null default 'New',
    "EstimatedTotal" numeric(18, 4) not null default 0,
    "CreatedAtUtc" timestamptz not null default now(),
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

create table if not exists public."AutomatedOrderLines" (
    "EntryNo" bigint generated always as identity primary key,
    "OrderNo" varchar(50) not null references public."AutomatedOrders"("OrderNo") on delete cascade,
    "CategoryCode" varchar(100),
    "ItemCode" varchar(200),
    "ItemName" varchar(255) not null,
    "Quantity" int not null default 1,
    "Price" numeric(18, 4) not null default 0
);

create index if not exists "IX_AutomatedOrderLines_OrderNo" on public."AutomatedOrderLines" ("OrderNo");

alter table public."AutomatedOrders" enable row level security;
alter table public."AutomatedOrderLines" enable row level security;
revoke all on public."AutomatedOrders" from anon, authenticated;
revoke all on public."AutomatedOrderLines" from anon, authenticated;

-- Added for direct Pancake order auto-creation (see submit_automated_order below):
-- "Location" is which physical branch/warehouse fulfills the order (customer-selected in
-- Step 4 - Amaya or GMA), used to resolve Pancake's warehouse_id by name. "Psid" is the
-- customer's Facebook PSID if they arrived via a Messenger-personalized order-now.html link
-- (see docs/js/orderNow.js's captureMessengerPsid()) - passed as customer.fb_id so Pancake
-- attaches the order to that existing conversation. PancakeOrderId/PancakeSyncStatus/
-- PancakeSyncError track whether/how the automatic Pancake push went - a failure there never
-- blocks the customer's request from being recorded (see the nested exception handler below).
alter table public."AutomatedOrders" add column if not exists "Location" varchar(20);
alter table public."AutomatedOrders" add column if not exists "Psid" varchar(255);
alter table public."AutomatedOrders" add column if not exists "PancakeOrderId" varchar(100);
alter table public."AutomatedOrders" add column if not exists "PancakeSyncStatus" varchar(20) not null default 'Pending';
alter table public."AutomatedOrders" add column if not exists "PancakeSyncError" text;

comment on table public."AutomatedOrders" is 'Customer-submitted order requests from the public order wizard (order-now.html) - a lead/request queue staff action manually, separate from the Pancake-synced OnlineOrders table.';
comment on table public."AutomatedOrderLines" is 'Line items for an AutomatedOrders request. Price/ItemName are snapshotted at submission time so the request stays accurate even if Items catalog prices change later.';

insert into public."NoSeries" ("SeriesCode", "Description", "Prefix", "Padding", "StartingNo", "WarehouseScoped")
select 'AUTOMATED-ORDER', 'Automated Order request number (customer order wizard)', 'AO-', 5, 1, false
where not exists (select 1 from public."NoSeries" where "SeriesCode" = 'AUTOMATED-ORDER');

-- ---------------------------------------------------------------------------
-- Public (anon, no login) catalog lookups - deliberately narrow: only Code/Name/Description/
-- Price/Images/QuantityInStock ever leave the server, never Cost/WholesalePrice/PromoPrice/etc
-- (same "pricing data stays behind a narrow view" intent as staff_list_items_by_category, just
-- taken one step further since these two are reachable with NO credentials at all).
-- ---------------------------------------------------------------------------

drop function if exists public.public_list_order_categories();

-- Every category is offered as a wizard button (per direct request: "I want to be able to show
-- all the categories in buttons") - a category with no active items right now just shows the
-- "No items available" empty state in step 2 (js/orderNow.js) rather than disappearing from
-- step 1 entirely.
create or replace function public.public_list_order_categories()
returns table(code text, description text)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select c."Code"::text, coalesce(nullif(trim(c."Description"), ''), c."Code")::text
  from public."Categories" c
  order by 2;
$$;

drop function if exists public.public_list_order_items(text);

create or replace function public.public_list_order_items(p_category_code text)
returns table(code text, name text, description text, price numeric, images text, quantity_in_stock int)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select
    i."Code"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")::text,
    i."Description"::text,
    coalesce(i."RetailPrice", i."Price", 0)::numeric,
    i."Images"::text,
    i."QuantityInStock"
  from public."Items" i
  where i."IsActive" is true
    and trim(coalesce(i."CategoryCode", '')) = trim(p_category_code)
  order by 2;
$$;

-- ---------------------------------------------------------------------------
-- Public (anon, no login) order submission - the only write path into AutomatedOrders/Lines.
-- Insert-only: builds and validates the whole request server-side rather than granting anon any
-- direct table insert, so a caller can never read back or edit someone else's request.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Shared Pancake-push worker - reads the already-inserted AutomatedOrders/Lines row by OrderNo
-- and tries to create the matching order in Pancake. Used by submit_automated_order (right after
-- the initial insert) AND by admin_retry_automated_order_pancake_push (staff "Retry Push to
-- Pancake" button for orders where PancakeSyncStatus = 'Failed') - kept as one function instead
-- of duplicating this logic in both places so the two paths can never drift apart. NEVER granted
-- to anon directly - only reachable through those two callers, which each do their own
-- authorization (submit_automated_order needs none, it's public by design; the retry RPC
-- re-verifies staff).
--
-- Always resolves to a PancakeSyncStatus of 'Synced' or 'Failed' on AutomatedOrders and never
-- raises out of this function - both callers can call it with a plain `perform` and immediately
-- re-read the row (or return void) to see the outcome.
-- ---------------------------------------------------------------------------

drop function if exists public._push_automated_order_to_pancake(text);

create or replace function public._push_automated_order_to_pancake(p_order_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_shop_id text := '1328301944';
  v_api_key text := 'e611861d2fc84607bfbbe1428a432447';
  v_page_id text := '195716644410829';
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_location text;
  v_warehouse_id text;
  v_line_count int;
  v_items_json jsonb;
  v_matched_count int;
  v_customer_json jsonb;
  v_shipping_json jsonb;
  v_payload jsonb;
  v_url text;
  v_response extensions.http_response;
  v_pancake_body jsonb;
  v_pancake_order_id text;
  v_lines_note text;
begin
  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;

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

    -- Full detail of every line, regardless of whether it matched a Pancake product below - per
    -- explicit request, this always rides along in the order's note field so staff reading the
    -- order in Pancake see exactly what was ordered (dimensions/glass/options/price for a Custom
    -- Aquarium line, not just a generic product name).
    select string_agg(l."ItemName" || ' x' || l."Quantity" || ' @ ' || l."Price", E'\n' order by l."EntryNo")
    into v_lines_note
    from public."AutomatedOrderLines" l
    where l."OrderNo" = p_order_no;

    -- Matched on Code (the normal catalog case - Standard flow lines always carry a real
    -- Items.ItemCode), OR on Name when there's no ItemCode at all - the Customize flow's
    -- Custom Aquarium line has no per-order Items.Code of its own (it's a one-off build, not a
    -- catalog SKU), so js/orderNow.js instead stamps CategoryCode = 'CUSTOM-AQUARIUM', which is
    -- that product's Items."Name", not its Items."Code" (confirmed live: Code = 'CI-005', Name =
    -- 'CUSTOM-AQUARIUM') - the "l.ItemCode is null" guard keeps this fallback scoped to exactly
    -- that case so it can never accidentally match a real catalog line by name collision.
    -- Also accepts EITHER identifier Pancake gave the matched product - VariationId (a normal
    -- catalog item with real variations) or, failing that, ProductId (a simple/service item
    -- Pancake never assigned a variation to, like CI-005 itself).
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
            'retail_price', l."Price"
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

    v_customer_json := jsonb_build_object(
      'name', v_order."CustomerName",
      'page_id', v_page_id
    ) || case when v_order."Psid" is not null then jsonb_build_object('fb_id', v_order."Psid") else '{}'::jsonb end;

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
      'customer', v_customer_json,
      'items', v_items_json,
      'note', 'Web order ' || p_order_no
        || coalesce(E'\n' || v_lines_note, '')
        || coalesce(' | Customer note: ' || nullif(trim(v_order."Notes"), ''), ''),
      'is_free_shipping', false,
      'shipping_fee', 0,
      'status', 0
    ) || case when v_shipping_json is not null then jsonb_build_object('shipping_address', v_shipping_json) else '{}'::jsonb end;

    v_url := v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key;
    v_response := extensions.http_post(v_url, v_payload::text, 'application/json');

    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake order creation failed (HTTP %): %', v_response.status, left(v_response.content, 500);
    end if;

    v_pancake_body := v_response.content::jsonb;
    v_pancake_order_id := coalesce(
      nullif(v_pancake_body ->> 'id', ''),
      nullif(v_pancake_body -> 'data' ->> 'id', ''),
      nullif(v_pancake_body ->> 'order_id', '')
    );

    update public."AutomatedOrders"
    set "PancakeOrderId" = v_pancake_order_id,
        "PancakeSyncStatus" = 'Synced',
        "PancakeSyncError" = null
    where "OrderNo" = p_order_no;
  exception when others then
    update public."AutomatedOrders"
    set "PancakeSyncStatus" = 'Failed',
        "PancakeSyncError" = left(sqlerrm, 1000)
    where "OrderNo" = p_order_no;
  end;
end;
$$;

-- No grant to anon - only called from submit_automated_order and
-- admin_retry_automated_order_pancake_push below, each of which handles its own authorization.

drop function if exists public.submit_automated_order(text, text, text, text, text, text, jsonb);
drop function if exists public.submit_automated_order(text, text, text, text, text, text, text, text, jsonb);

-- p_lines: jsonb array of {"category_code","item_code","item_name","quantity","price"} - built
-- client-side from the wizard's cart (js/orderNow.js). item_name/price are trusted from the
-- client only as a display snapshot; nothing here grants pricing authority, this is a request
-- queue staff review and action manually (fulfillment/final pricing happens off this table).
--
-- p_location: which branch fulfills the order ("Amaya"/"GMA", Step 4's new branch picker) -
-- resolves Pancake's warehouse_id by matching public."Warehouses"."Name". p_psid: the
-- customer's Facebook PSID if captured from a Messenger-personalized link (nullable - most
-- submissions won't have one, and that's fine, just means the Pancake order isn't
-- auto-attached to an existing conversation).
--
-- After recording the request locally (unchanged from before), this ALSO tries to create a real
-- order in Pancake via public._push_automated_order_to_pancake() above, so staff see it in
-- Pancake without re-keying anything. That helper never raises - if Pancake is unreachable, a
-- line item has no matching Items."VariationId", or anything else goes wrong, the customer's
-- request is still recorded and OrderNo still returned; the failure is only visible via
-- AutomatedOrders."PancakeSyncStatus"/"PancakeSyncError" (surfaced on the Automated Orders staff
-- page, with a "Retry Push to Pancake" button - see admin_retry_automated_order_pancake_push).
create or replace function public.submit_automated_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_psid text,
  p_lines jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_psid text := nullif(trim(coalesce(p_psid, '')), '');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
  v_line_count int := 0;
begin
  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
  -- The real gate (js/orderNow.js's isValidPhMobileNumber does the same check client-side, but
  -- that's only a UX nicety - this is what actually stops junk like "test" from reaching
  -- AutomatedOrders/Pancake, since Pancake's own order API rejects it with an unhelpfully empty
  -- 422 error rather than a clear validation message). Accepts PH mobile numbers in local
  -- (09171234567), country-code (639171234567), or +-prefixed (+639171234567) form.
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
    ("OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status", "EstimatedTotal", "Location", "Psid")
  values
    (v_order_no, trim(p_customer_name), trim(p_customer_phone), nullif(trim(coalesce(p_customer_email, '')), ''),
     v_fulfillment, case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
     nullif(trim(coalesce(p_notes, '')), ''), 'New', 0, v_location, v_psid);

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
    v_line_count := v_line_count + 1;
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = v_order_no;

  perform public._push_automated_order_to_pancake(v_order_no);

  return v_order_no;
end;
$$;

-- ---------------------------------------------------------------------------
-- Staff-facing read/update (docs/automated-orders.html / js/automatedOrders.js) - open to any
-- active staff login, same tier as admin_list_online_orders/Delivery, since a fast follow-up
-- with the customer matters more than restricting this to super users.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_list_automated_orders(text, text, text, text, int, int);

create or replace function public.admin_list_automated_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  order_no text,
  customer_name text,
  customer_phone text,
  customer_email text,
  fulfillment_type text,
  delivery_address text,
  notes text,
  status text,
  estimated_total numeric,
  created_at_utc timestamptz,
  updated_by text,
  updated_at_utc timestamptz,
  location text,
  psid text,
  pancake_order_id text,
  pancake_sync_status text,
  pancake_sync_error text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."OrderNo"::text, o."CustomerName"::text, o."CustomerPhone"::text, o."CustomerEmail"::text,
           o."FulfillmentType"::text, o."DeliveryAddress"::text, o."Notes"::text, o."Status"::text,
           o."EstimatedTotal", o."CreatedAtUtc", o."UpdatedBy"::text, o."UpdatedAtUtc",
           o."Location"::text, o."Psid"::text, o."PancakeOrderId"::text, o."PancakeSyncStatus"::text, o."PancakeSyncError"::text,
           count(*) over()
    from public."AutomatedOrders" o
    where (p_status is null or trim(p_status) = '' or o."Status" ilike p_status)
      and (
        p_search is null or trim(p_search) = ''
        or o."OrderNo" ilike '%' || p_search || '%'
        or o."CustomerName" ilike '%' || p_search || '%'
        or o."CustomerPhone" ilike '%' || p_search || '%'
      )
    order by o."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_list_automated_order_lines(text, text, text);

create or replace function public.admin_list_automated_order_lines(p_admin_username text, p_admin_password text, p_order_no text)
returns table(entry_no bigint, category_code text, item_code text, item_name text, quantity int, price numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select l."EntryNo", l."CategoryCode"::text, l."ItemCode"::text, l."ItemName"::text, l."Quantity", l."Price"
    from public."AutomatedOrderLines" l
    where l."OrderNo" = p_order_no
    order by l."EntryNo";
end;
$$;

-- Staff "Retry Push to Pancake" button (docs/automated-orders.html) - only meaningful/shown when
-- PancakeSyncStatus = 'Failed' (retrying a 'Synced' order would create a SECOND order in Pancake,
-- since order creation has no idempotency key to upsert against - js/automatedOrders.js only
-- renders this button for Failed rows). Re-verifies staff, then re-runs the exact same worker
-- submit_automated_order used initially, and returns the fresh outcome so the UI can update
-- immediately without a second round-trip.
drop function if exists public.admin_retry_automated_order_pancake_push(text, text, text);

create or replace function public.admin_retry_automated_order_pancake_push(p_admin_username text, p_admin_password text, p_order_no text)
returns table(pancake_sync_status text, pancake_sync_error text, pancake_order_id text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  perform public._push_automated_order_to_pancake(p_order_no);

  return query
    select o."PancakeSyncStatus"::text, o."PancakeSyncError"::text, o."PancakeOrderId"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = p_order_no;
end;
$$;

drop function if exists public.admin_update_automated_order_status(text, text, text, text);

create or replace function public.admin_update_automated_order_status(p_admin_username text, p_admin_password text, p_order_no text, p_status text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_status not in ('New', 'Contacted', 'Confirmed', 'Completed', 'Cancelled') then
    raise exception 'Invalid status.';
  end if;

  update public."AutomatedOrders"
    set "Status" = p_status, "UpdatedBy" = p_admin_username, "UpdatedAtUtc" = now()
    where "OrderNo" = p_order_no;
end;
$$;

grant execute on function public.public_list_order_categories() to anon;
grant execute on function public.public_list_order_items(text) to anon;
grant execute on function public.submit_automated_order(text, text, text, text, text, text, text, text, jsonb) to anon;
grant execute on function public.admin_list_automated_orders(text, text, text, text, int, int) to anon;
grant execute on function public.admin_list_automated_order_lines(text, text, text) to anon;
grant execute on function public.admin_retry_automated_order_pancake_push(text, text, text) to anon;
grant execute on function public.admin_update_automated_order_status(text, text, text, text) to anon;
