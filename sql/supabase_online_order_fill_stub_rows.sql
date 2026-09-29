-- Fills in GMA orders stuck as empty "stub" rows on Online Orders - per "the order coming from GMA page is
-- a custom order. why it is not treating as Custom order and cannot be assigned a maker" (order 104569:
-- Status/Customer/Date/Warehouse all blank, only Confirmed By set).
--
-- CAUSE: GMA Conversations' Confirm (admin_confirm_gma_order_in_pancake, supabase_gma_conversation_
-- pancake_confirm.sql) inserts a stub OnlineOrders row - just OrderID/ConfirmedBy/ConfirmedAtUtc - and
-- leaves the rest to the every-minute header sync. That sync only reads orders Pancake reports as
-- updated after its cursor, so it can miss one (the reason cron_refresh_open_online_orders exists). But
-- that refresh only picks rows whose Status is already Confirmed/Printed/..., and a stub has NO Status -
-- so nothing ever fills it: no status (can't be Assigned), no customer/warehouse.
--
-- FIX: cron_refresh_open_online_orders also picks stub rows (blank Status), and _refresh_open_online_order
-- fills a stub's header from the same Pancake detail it already fetches - same field mapping as the header
-- sync (cron_sync_online_orders_from_pancake, supabase_online_order_sync_edited_lines.sql). Lines come
-- from cron_sync_online_order_details, which already picks orders with no lines. A stub whose Pancake
-- order is still 'new' is skipped (bumped to the back of the rotation) until it's confirmed.
--
-- Run AFTER supabase_online_order_sync_no_long_locks.sql. Replaces one function + one procedure (the cron
-- job calls the procedure by name - no reschedule). No table locks.

create or replace function public._refresh_open_online_order(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_response extensions.http_response;
  v_body jsonb;
  v_el jsonb;
  v_status_raw text;
  v_status text;
  v_updated_utc timestamptz;
  v_is_stub boolean;
  v_created_utc timestamptz;
  v_money numeric;
  v_paid numeric;
  v_created_by text;
  v_confirmed_by text;
  v_confirmed_at timestamptz;
  v_free_ship_kind text;
begin
  select nullif(trim(coalesce("Status", '')), '') is null into v_is_stub
  from public."OnlineOrders" where "OrderID" = p_order_id;

  v_response := extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id
    || '?api_key=' || public._pancake_api_key());
  if v_response.status < 200 or v_response.status >= 300 then
    return;
  end if;

  v_body := v_response.content::jsonb;
  v_el := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' then v_body
    else null
  end;
  if v_el is null then
    return;
  end if;

  v_status_raw := coalesce(v_el ->> 'status_name', v_el ->> 'status', v_el ->> 'state', v_el ->> 'order_status');
  if v_status_raw is null or lower(trim(v_status_raw)) in ('', 'new') then
    -- Still 'new' in Pancake: move a stub to the back of the rotation so it doesn't hog every run.
    if v_is_stub then
      update public."OnlineOrders" set "SyncedAtUtc" = now() where "OrderID" = p_order_id;
    end if;
    return;
  end if;

  -- Same mapping as cron_refresh_open_online_order_statuses (Assigned/"waitting" is normalized by the
  -- OnlineOrders status trigger).
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

  begin
    v_updated_utc := coalesce(v_el ->> 'updated_at', v_el ->> 'last_updated_at')::timestamptz;
  exception when others then
    v_updated_utc := null;
  end;

  -- No saved lines yet (a just-filled stub, or a new order): save them now. OnlineOrderLines drives the
  -- Custom badge and the Tank/Stand Maker slots (the order card shows Pancake's lines live, so it can look
  -- right while these are still missing) - per "its still not showing custom upon sync on the portal"
  -- (order 104609). Only for orders with no lines, so the rotation doesn't double its Pancake calls.
  --
  -- Runs BEFORE this function's own OnlineOrders updates below, on purpose: _sync_online_order_detail
  -- makes a Pancake call, and making it after updating the order would hold that order's row lock for
  -- the whole call - which made Assign time out ("Tank Maker: canceling statement due to statement
  -- timeout", order 104640; same problem supabase_online_order_sync_no_long_locks.sql fixed). Its own
  -- writes happen after its Pancake call, so the lock is only held for quick local work.
  if not exists (select 1 from public."OnlineOrderLines" l where l."OrderID" = p_order_id) then
    begin
      perform public._sync_online_order_detail(p_order_id);
    exception when others then
      null; -- cron_sync_online_order_details still retries it
    end;
  end if;

  update public."OnlineOrders"
    set "Status" = v_status,
        "Last_Updated_At" = coalesce(v_updated_utc, "Last_Updated_At"),
        "SyncedAtUtc" = now()
    where "OrderID" = p_order_id;

  -- Stub row: fill the header the same way the header sync does.
  if v_is_stub then
    v_created_utc := public.pancake_try_parse_timestamptz(coalesce(v_el ->> 'inserted_at', v_el ->> 'insertedAt', v_el ->> 'created_at', v_el ->> 'createdAt', v_el ->> 'date', v_el ->> 'created'));
    v_money := public.pancake_parse_decimal(coalesce(
      v_el -> 'money_to_collect' ->> 'amount', v_el -> 'money_to_collect' ->> 'value', v_el -> 'money_to_collect' ->> 'total',
      v_el ->> 'money_to_collect', v_el ->> 'moneyToCollect', v_el ->> 'total_price', v_el ->> 'total', v_el ->> 'amount', v_el ->> 'money'));
    v_paid := public.pancake_parse_decimal(coalesce(
      v_el -> 'prepaid' ->> 'amount', v_el -> 'prepaid' ->> 'value',
      v_el ->> 'prepaid', v_el ->> 'prepaid_amount', v_el ->> 'pre_paid', v_el ->> 'deposit', v_el ->> 'prepayment'));
    select t.created_by, t.confirmed_by, t.confirmed_at into v_created_by, v_confirmed_by, v_confirmed_at
    from public.pancake_extract_created_confirmed_by(v_el) t;
    v_free_ship_kind := jsonb_typeof(v_el -> 'is_free_shipping');

    update public."OnlineOrders"
      set "Date" = (v_created_utc at time zone 'Asia/Manila')::date,
          "Time" = to_char(v_created_utc at time zone 'Asia/Manila', 'HH24:MI:SS'),
          "CustomerName" = coalesce(
            v_el -> 'customer' ->> 'name', v_el -> 'customer' ->> 'customer_name', v_el -> 'customer' ->> 'full_name',
            v_el ->> 'customer_name', v_el ->> 'bill_full_name', v_el ->> 'client_name', v_el ->> 'buyer_name'),
          "Page_ID" = coalesce(v_el ->> 'page_id', v_el ->> 'pageId', v_el ->> 'page'),
          "Conversation_ID" = coalesce(v_el ->> 'conversation_id', v_el ->> 'conversationId', v_el ->> 'thread_id', v_el ->> 'threadId'),
          "LocationID" = coalesce(v_el ->> 'warehouse_id', v_el ->> 'warehouseId'),
          "MoneyToCollect" = v_money,
          "AmountPaid" = v_paid,
          "Balance" = v_money - v_paid, -- computed locally, same as the header sync
          "Discount" = public.pancake_parse_decimal(coalesce(v_el ->> 'discount', v_el ->> 'discount_amount', v_el ->> 'discounted_amount')),
          "DeliveryFee" = public.pancake_parse_decimal(coalesce(
            v_el -> 'shipping_fee' ->> 'amount', v_el -> 'shipping_fee' ->> 'value',
            v_el ->> 'shipping_fee', v_el ->> 'shippingFee', v_el ->> 'delivery_fee', v_el ->> 'deliveryFee')),
          "ForDelivery" = case v_free_ship_kind
            when 'boolean' then (v_el ->> 'is_free_shipping')::boolean
            when 'number' then (v_el ->> 'is_free_shipping')::numeric <> 0
            when 'string' then lower(trim(v_el ->> 'is_free_shipping')) in ('true', 'yes', 'y', 'on', '1')
            else false
          end,
          "ShippingAddress" = coalesce(
            v_el -> 'shipping_address' ->> 'full_address', v_el -> 'shipping_address' ->> 'fullAddress',
            v_el -> 'shipping_address' ->> 'address', v_el ->> 'full_address', v_el ->> 'fullAddress'),
          "ShippingPhone" = coalesce(
            v_el -> 'shipping_address' ->> 'phone_number', v_el -> 'shipping_address' ->> 'phoneNumber',
            v_el ->> 'phone_number', v_el ->> 'bill_phone_number', v_el -> 'customer' ->> 'phone_number', v_el -> 'customer' ->> 'phone'),
          "Converted_LastUpdated_At" = case when v_updated_utc is not null then (v_updated_utc at time zone 'Asia/Manila')::date else null end,
          "CreatedBy" = coalesce(v_created_by, "CreatedBy"),
          "ConfirmedBy" = coalesce("ConfirmedBy", v_confirmed_by),
          "ConfirmedAtUtc" = coalesce("ConfirmedAtUtc", v_confirmed_at)
      where "OrderID" = p_order_id;
  end if;

end;
$$;

revoke execute on function public._refresh_open_online_order(text) from public, anon, authenticated;

-- Same as supabase_online_order_sync_no_long_locks.sql's version, plus stub rows (blank Status).
create or replace procedure public.cron_refresh_open_online_orders(p_max_orders int default 40)
language plpgsql
as $$
declare
  v_order_id text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');

  for v_order_id in
    select "OrderID" from public."OnlineOrders"
    where ("Status" in ('Confirmed', 'Printed', 'Assigned', 'To Ship', 'In-Transit', 'Pending Transfer')
           or nullif(trim(coalesce("Status", '')), '') is null)
      and coalesce("ReceivedAtShop", false) is not true
    order by "SyncedAtUtc" asc nulls first
    limit least(greatest(coalesce(p_max_orders, 40), 1), 200)
  loop
    begin
      perform public._refresh_open_online_order(v_order_id);
    exception when others then
      null; -- retried on a future run
    end;
    commit;
  end loop;
end;
$$;

revoke execute on procedure public.cron_refresh_open_online_orders(int) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- CHECK (optional): an order's saved lines. Expect maker_part = 'tank' on each CUSTOM-AQUARIUM line
-- (that's what shows the Custom badge). The cron job saves a new order's lines within about a minute.
select "OrderID", "LineID", "ItemCode", "Description", public._online_order_line_part("Description", "ItemCode", "product_display_id") as maker_part
from public."OnlineOrderLines" where "OrderID" in ('104640');
