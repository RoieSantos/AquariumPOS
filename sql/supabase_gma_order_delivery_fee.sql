-- GMA Conversations: Delivery Fee on Create / Edit Order - per "in the portal conversation .. where can we
-- add delivery fee?" -> "yes please".
--
-- New AutomatedOrders."DeliveryFee" (portal only, 0 = none / free delivery). Set from a "Delivery Fee"
-- box under Delivery Address on the Create Order tab (shown only for Delivery; Pickup always saves 0).
-- The fee is part of the order's money everywhere:
--   * "EstimatedTotal" = items + fee, so the order card's Total / Balance, Add Payment and the AI bot's
--     order lookups all include it.
--   * Confirm Order (admin_confirm_bot_order) copies it into OnlineOrders."DeliveryFee" and adds it to
--     "MoneyToCollect" / "Balance" - the same fields Pancake orders fill from Pancake's shipping_fee, so
--     the Online Orders page, Delivery page (its manual fee per stop still overrides it), receipts and
--     the bot's delivery-scheduling tool pick it up with no other change.
--   * Customer receipt (public_get_automated_order_receipt) shows it in its existing delivery_fee field
--     (was hard-coded 0); the staff Invoice (admin_get_automated_order_invoice) adds a "Delivery Fee" line.
-- Old Pancake-backed orders (Pending / Synced / Failed / Stale) refuse a fee - it would never reach
-- Pancake (set it in Pancake instead). Confirmed (Portal) orders still can't be edited here, as before.
--
-- Re-creates (each = the live def + only the fee):
--   admin_create_gma_conversation_order  (supabase_gma_new_order_no_pancake.sql)              + p_delivery_fee
--   admin_update_automated_order         (supabase_bot_orders_portal_confirm.sql section 3)    + p_delivery_fee
--   admin_confirm_bot_order              (supabase_bot_orders_portal_confirm.sql section 1)
--   admin_list_automated_orders_by_gma_conversation (supabase_gma_conversations_staff_rpc_access.sql section 4) + delivery_fee column
--   public_get_automated_order_receipt   (supabase_order_receipt_letterhead.sql 2a)
--   admin_get_automated_order_invoice    (supabase_gma_conversation_order_invoice.sql)
-- Run AFTER supabase_gma_new_order_no_pancake.sql and supabase_order_receipt_letterhead.sql. Safe to
-- re-run. If any of those files is ever re-run, run this one again afterwards.
-- Needs js/gmaConversations.js ?v=delivfee1.

alter table public."AutomatedOrders" add column if not exists "DeliveryFee" numeric(18, 2) not null default 0;

comment on column public."AutomatedOrders"."DeliveryFee" is 'Delivery fee staff set on a GMA Conversations order (0 = none / free). Included in EstimatedTotal; copied to OnlineOrders.DeliveryFee on Confirm Order. Portal only - never sent to Pancake.';

-- ---------------------------------------------------------------------------
-- 1. admin_create_gma_conversation_order: + p_delivery_fee

drop function if exists public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb);
drop function if exists public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb, numeric);

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
  p_lines jsonb,
  p_delivery_fee numeric default null
)
returns table(order_no text, pancake_order_id text, pancake_sync_status text, pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '90000'
as $$
declare
  v_order_no text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
  v_delivery_fee numeric(18, 2);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
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
  -- This file: Pickup never carries a fee.
  if coalesce(p_delivery_fee, 0) < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;
  v_delivery_fee := case when v_fulfillment = 'Delivery' then round(coalesce(p_delivery_fee, 0), 2) else 0 end;

  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');

  insert into public."AutomatedOrders"
    ("OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status", "EstimatedTotal", "Location", "GmaPsid", "GmaPageId", "UpdatedBy", "PancakeSyncStatus", "DeliveryFee")
  values
    (v_order_no, trim(p_customer_name), trim(p_customer_phone), nullif(trim(coalesce(p_customer_email, '')), ''),
     v_fulfillment, case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
     nullif(trim(coalesce(p_notes, '')), ''), 'New', 0, v_location, trim(p_psid), nullif(trim(coalesce(p_page_id, '')), ''), p_admin_username, 'Not Pushed',
     v_delivery_fee);

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
      (v_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price,
       nullif(trim(coalesce(v_line->>'note', '')), ''), nullif(trim(coalesce(v_line->>'variation_id', '')), ''));

    v_total := v_total + (v_qty * v_price);
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total + v_delivery_fee where "OrderNo" = v_order_no;

  -- No Pancake push - staff confirm it into Online Orders with "Confirm Order" (admin_confirm_bot_order).

  return query
    select o."OrderNo"::text, o."PancakeOrderId"::text, o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = v_order_no;
end;
$$;

grant execute on function public.admin_create_gma_conversation_order(text, text, text, text, text, text, text, text, text, text, text, jsonb, numeric) to anon;

-- ---------------------------------------------------------------------------
-- 2. admin_update_automated_order: + p_delivery_fee (null = keep the current fee)

drop function if exists public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb);
drop function if exists public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb, numeric);

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
  p_lines jsonb,
  p_delivery_fee numeric default null
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
  v_current_fee numeric(18, 2);
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
  v_delivery_fee numeric(18, 2);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "Status", "PancakeSyncStatus", coalesce("DeliveryFee", 0) into v_current_status, v_current_sync_status, v_current_fee
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
  -- This file: the fee (null = keep it; Pickup = 0). Portal drafts only - an old Pancake-backed order's
  -- fee would never reach Pancake.
  if coalesce(p_delivery_fee, 0) < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;
  v_delivery_fee := case when v_fulfillment = 'Delivery' then round(coalesce(p_delivery_fee, v_current_fee), 2) else 0 end;
  if v_delivery_fee <> v_current_fee and coalesce(v_current_sync_status, '') <> 'Not Pushed' then
    raise exception 'Order % is a Pancake order - set its delivery fee in Pancake instead.', p_order_no;
  end if;

  update public."AutomatedOrders"
  set "CustomerName" = trim(p_customer_name),
      "CustomerPhone" = trim(p_customer_phone),
      "CustomerEmail" = nullif(trim(coalesce(p_customer_email, '')), ''),
      "FulfillmentType" = v_fulfillment,
      "DeliveryAddress" = case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
      "Notes" = nullif(trim(coalesce(p_notes, '')), ''),
      "Location" = v_location,
      "DeliveryFee" = v_delivery_fee,
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

  update public."AutomatedOrders" set "EstimatedTotal" = v_total + v_delivery_fee where "OrderNo" = p_order_no;

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

grant execute on function public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb, numeric) to anon;

-- ---------------------------------------------------------------------------
-- 3. admin_confirm_bot_order: the fee goes into OnlineOrders."DeliveryFee" and the amount to collect

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
  v_fee numeric(18, 2);
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

  -- This file: items + delivery fee (0 for Pickup / none set).
  v_fee := case when v_order."FulfillmentType" = 'Delivery' then coalesce(v_order."DeliveryFee", 0) else 0 end;
  select coalesce(sum(l."Quantity" * l."Price"), 0) + v_fee into v_total
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
    "MoneyToCollect", "AmountPaid", "Discount", "Balance", "DeliveryFee",
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
    v_total, v_paid, 0, v_total - v_paid, nullif(v_fee, 0),
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
-- 4. admin_list_automated_orders_by_gma_conversation: + delivery_fee (Edit Order prefill)

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
  customer_email text,
  fulfillment_type text,
  delivery_address text,
  location text,
  notes text,
  status text,
  estimated_total numeric,
  amount_paid numeric,
  balance numeric,
  pancake_order_id text,
  pancake_order_link text,
  pancake_sync_status text,
  receipt_confirmed_at_utc timestamptz,
  created_at_utc timestamptz,
  delivery_fee numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
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
      o."CustomerEmail"::text,
      o."FulfillmentType"::text,
      o."DeliveryAddress"::text,
      o."Location"::text,
      o."Notes"::text,
      o."Status"::text,
      o."EstimatedTotal",
      coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"), 0)::numeric,
      (o."EstimatedTotal" - coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo"), 0))::numeric,
      o."PancakeOrderId"::text,
      o."PancakeOrderLink"::text,
      o."PancakeSyncStatus"::text,
      o."ReceiptConfirmedAtUtc",
      o."CreatedAtUtc",
      coalesce(o."DeliveryFee", 0)::numeric
    from public."AutomatedOrders" o
    where o."GmaPsid" = trim(p_psid)
      and (p_page_id is null or trim(p_page_id) = '' or o."GmaPageId" = trim(p_page_id))
    order by o."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_automated_orders_by_gma_conversation(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 5. public_get_automated_order_receipt: delivery_fee = the order's fee (was always 0). Same columns,
--    so the public_get_order_receipt wrapper is untouched.

create or replace function public.public_get_automated_order_receipt(p_order_no text)
returns table(
  order_id text,
  pancake_order_id text,
  order_date date,
  customer_name text,
  shipping_address text,
  status_label text,
  warehouse_name text,
  warehouse_address text,
  delivery_fee numeric,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
  balance numeric,
  note_print text,
  line_no int,
  line_description text,
  line_quantity numeric,
  line_amount numeric,
  line_note text,
  sales_staff text,
  customer_phone text,
  warehouse_contact text,
  line_code text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_order_no text := trim(p_order_no);
  v_warehouse_name text;
  v_warehouse_address text;
  v_warehouse_contact text;
  v_amount_paid numeric;
  v_status_label text;
  v_sales_staff text;
  v_line record;
  v_line_no int := 0;
begin
  select * into v_order from public."AutomatedOrders" where "OrderNo" = v_order_no;
  if not found then
    return;
  end if;

  select w."Name"::text, w."Address"::text, w."ContactNo"::text
  into v_warehouse_name, v_warehouse_address, v_warehouse_contact
  from public."Warehouses" w
  where w."Name" ilike '%' || coalesce(nullif(trim(v_order."Location"), ''), 'Amaya') || '%'
  order by w."Name"
  limit 1;

  v_warehouse_name := coalesce(v_warehouse_name, v_order."Location");

  select coalesce(sum(p."Amount"), 0) into v_amount_paid
  from public."AutomatedOrderPayments" p
  where p."OrderNo" = v_order_no;

  -- Who confirmed it (once it's in Online Orders), else who created it.
  select coalesce(
           (select nullif(trim(oo."ConfirmedBy"), '') from public."OnlineOrders" oo where oo."OrderID" = v_order."PancakeReceiptNo"),
           case when v_order."UpdatedBy" = 'AI Bot' then 'Online Assistant' end,
           (select nullif(trim(s."DisplayName"), '') from public."StaffUsers" s where s."Username" = v_order."UpdatedBy"),
           nullif(trim(v_order."UpdatedBy"), ''))
    into v_sales_staff;

  v_status_label := case v_order."Status"
    when 'New' then 'Order Received - Pending Confirmation'
    when 'Contacted' then 'Contacted'
    when 'Confirmed' then 'Confirmed'
    when 'Completed' then 'Completed'
    when 'Cancelled' then 'Cancelled'
    else v_order."Status"
  end;

  for v_line in
    select l."ItemName"::text as description, l."Quantity" as quantity,
           (l."Price" * l."Quantity") as amount,
           nullif(trim(l."Notes"::text), '') as note,
           coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."CategoryCode"), ''))::text as code
    from public."AutomatedOrderLines" l
    where l."OrderNo" = v_order_no
    order by l."EntryNo"
  loop
    v_line_no := v_line_no + 1;
    order_id := v_order_no;
    pancake_order_id := v_order."PancakeOrderId"::text;
    order_date := v_order."CreatedAtUtc"::date;
    customer_name := v_order."CustomerName"::text;
    shipping_address := case when v_order."FulfillmentType" = 'Delivery' then v_order."DeliveryAddress"::text else null end;
    status_label := v_status_label;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    delivery_fee := coalesce(v_order."DeliveryFee", 0);   -- this file
    money_to_collect := v_order."EstimatedTotal";
    amount_paid := v_amount_paid;
    discount := 0;
    balance := v_order."EstimatedTotal" - v_amount_paid;
    note_print := nullif(trim(v_order."Notes"::text), '');
    line_no := v_line_no;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    line_amount := v_line.amount;
    line_note := v_line.note;
    sales_staff := v_sales_staff;
    customer_phone := v_order."CustomerPhone"::text;
    warehouse_contact := v_warehouse_contact;
    line_code := v_line.code;
    return next;
  end loop;

  if v_line_no = 0 then
    order_id := v_order_no;
    pancake_order_id := v_order."PancakeOrderId"::text;
    order_date := v_order."CreatedAtUtc"::date;
    customer_name := v_order."CustomerName"::text;
    shipping_address := case when v_order."FulfillmentType" = 'Delivery' then v_order."DeliveryAddress"::text else null end;
    status_label := v_status_label;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    delivery_fee := coalesce(v_order."DeliveryFee", 0);   -- this file
    money_to_collect := v_order."EstimatedTotal";
    amount_paid := v_amount_paid;
    discount := 0;
    balance := v_order."EstimatedTotal" - v_amount_paid;
    note_print := nullif(trim(v_order."Notes"::text), '');
    line_no := null;
    line_description := null;
    line_quantity := null;
    line_amount := null;
    line_note := null;
    sales_staff := v_sales_staff;
    customer_phone := v_order."CustomerPhone"::text;
    warehouse_contact := v_warehouse_contact;
    line_code := null;
    return next;
  end if;
end;
$$;

grant execute on function public.public_get_automated_order_receipt(text) to anon;

-- ---------------------------------------------------------------------------
-- 6. admin_get_automated_order_invoice: + a "Delivery Fee" line after the items, so the lines add up
--    to the Total (which now includes the fee).

create or replace function public.admin_get_automated_order_invoice(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(
  order_no text,
  order_date date,
  customer_name text,
  customer_phone text,
  shipping_address text,
  location text,
  warehouse_name text,
  warehouse_address text,
  sales_staff text,
  status_label text,
  total numeric,
  amount_paid numeric,
  balance numeric,
  note_print text,
  line_no int,
  line_description text,
  line_quantity numeric,
  line_amount numeric,
  line_note text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_order_no text := trim(p_order_no);
  v_warehouse_name text;
  v_warehouse_address text;
  v_amount_paid numeric;
  v_status_label text;
  v_line record;
  v_line_no int := 0;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_order from public."AutomatedOrders" where "OrderNo" = v_order_no;
  if not found then
    raise exception 'Order % not found.', v_order_no;
  end if;

  select w."Name"::text, w."Address"::text
  into v_warehouse_name, v_warehouse_address
  from public."Warehouses" w
  where w."Name" ilike '%' || coalesce(nullif(trim(v_order."Location"), ''), 'Amaya') || '%'
  order by w."Name"
  limit 1;

  v_warehouse_name := coalesce(v_warehouse_name, v_order."Location");

  select coalesce(sum(p."Amount"), 0) into v_amount_paid
  from public."AutomatedOrderPayments" p
  where p."OrderNo" = v_order_no;

  v_status_label := case v_order."Status"
    when 'New' then 'Order Received - Pending Confirmation'
    when 'Contacted' then 'Contacted'
    when 'Confirmed' then 'Confirmed'
    when 'Completed' then 'Completed'
    when 'Cancelled' then 'Cancelled'
    else v_order."Status"
  end;

  -- This file: the fee rides along as a last line (sort_key 1, after every item).
  for v_line in
    select x.description, x.quantity, x.amount, x.note
    from (
      select 0 as sort_key, l."EntryNo" as entry_no,
             l."ItemName"::text as description, l."Quantity"::numeric as quantity,
             (l."Price" * l."Quantity")::numeric as amount,
             nullif(trim(l."Notes"::text), '') as note
      from public."AutomatedOrderLines" l
      where l."OrderNo" = v_order_no
      union all
      select 1, null, 'Delivery Fee', 1::numeric, v_order."DeliveryFee"::numeric, null::text
      where coalesce(v_order."DeliveryFee", 0) > 0
    ) x
    order by x.sort_key, x.entry_no
  loop
    v_line_no := v_line_no + 1;
    order_no := v_order_no;
    order_date := v_order."CreatedAtUtc"::date;
    customer_name := v_order."CustomerName"::text;
    customer_phone := v_order."CustomerPhone"::text;
    shipping_address := case when v_order."FulfillmentType" = 'Delivery' then v_order."DeliveryAddress"::text else 'Pickup' end;
    location := v_order."Location"::text;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    sales_staff := v_order."UpdatedBy"::text;
    status_label := v_status_label;
    total := v_order."EstimatedTotal";
    amount_paid := v_amount_paid;
    balance := v_order."EstimatedTotal" - v_amount_paid;
    note_print := nullif(trim(v_order."Notes"::text), '');
    line_no := v_line_no;
    line_description := v_line.description;
    line_quantity := v_line.quantity;
    line_amount := v_line.amount;
    line_note := v_line.note;
    return next;
  end loop;

  if v_line_no = 0 then
    order_no := v_order_no;
    order_date := v_order."CreatedAtUtc"::date;
    customer_name := v_order."CustomerName"::text;
    customer_phone := v_order."CustomerPhone"::text;
    shipping_address := case when v_order."FulfillmentType" = 'Delivery' then v_order."DeliveryAddress"::text else 'Pickup' end;
    location := v_order."Location"::text;
    warehouse_name := v_warehouse_name;
    warehouse_address := v_warehouse_address;
    sales_staff := v_order."UpdatedBy"::text;
    status_label := v_status_label;
    total := v_order."EstimatedTotal";
    amount_paid := v_amount_paid;
    balance := v_order."EstimatedTotal" - v_amount_paid;
    note_print := nullif(trim(v_order."Notes"::text), '');
    line_no := null;
    line_description := null;
    line_quantity := null;
    line_amount := null;
    line_note := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_automated_order_invoice(text, text, text) to anon;

notify pgrst, 'reload schema';
