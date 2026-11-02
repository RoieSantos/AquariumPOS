-- Xendit: auto-confirm a paid order - per "once the order is paid can the order be confirmed?". A real payment
-- that brings an order waiting for confirmation up to the 50% down payment (_xendit_down_payment_due) now
-- confirms it, the same as staff clicking Confirm Order. ConfirmedBy = 'Xendit'.
--
--   - Test payments never confirm an order and don't count towards the 50%.
--   - Below 50% the order keeps waiting for staff.
--   - The payment is always safe: this runs after it is recorded and never raises. If confirming fails, the order
--     keeps waiting, the reason shows on the Xendit Payments row and staff get a Telegram alert.
--   - The order row is locked first, so a repeated webhook or a staff click at the same moment can't confirm twice.
--
-- admin_confirm_bot_order is now the login check + _confirm_bot_order (its body is otherwise unchanged from
-- supabase_gma_order_delivery_fee.sql). xendit-webhook sends the customer the "order confirmed" message.
--
-- Run AFTER supabase_gma_order_delivery_fee.sql, supabase_xendit_payment_receipt_page.sql and
-- supabase_telegram_notifications.sql. Safe to re-run. Needs the Edge Function xendit-webhook redeployed.

-- ---------------------------------------------------------------------------
-- 1. Confirm Order, without the login check. Internal only.

create or replace function public._confirm_bot_order(p_order_no text, p_confirmed_by text)
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

  -- Items + delivery fee (0 for Pickup / none set).
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
  from public."StaffUsers" where "Username" = p_confirmed_by;

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
    coalesce(nullif(trim(v_order."UpdatedBy"), ''), 'AI Bot'), coalesce(v_confirmed_by, p_confirmed_by), v_now, 'Portal'
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
      "UpdatedBy" = p_confirmed_by,
      "UpdatedAtUtc" = v_now
  where "OrderNo" = p_order_no;

  return query select p_order_no::text, 'Confirmed'::text;
end;
$$;

revoke all on function public._confirm_bot_order(text, text) from public, anon, authenticated;

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
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query select c.online_order_id, c.order_status from public._confirm_bot_order(p_order_no, p_admin_username) c;
end;
$$;

grant execute on function public.admin_confirm_bot_order(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Edge Function only: called after a payment is recorded and applied. Never raises.
--    Returns message_id / psid / page_id / message only when this call confirmed the order and has a chat to tell.

create or replace function public._xendit_try_auto_confirm(p_payment_id uuid)
returns table(confirmed boolean, message_id bigint, psid text, page_id text, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  x public."XenditPayments"%rowtype;
  v_order public."AutomatedOrders"%rowtype;
  v_total numeric;
  v_paid numeric;
  v_psid text;
  v_page_id text;
  v_text text;
  v_message_id bigint;
  v_error text;
begin
  select * into x from public."XenditPayments" where "PaymentID" = p_payment_id;
  if not found or x."Status" <> 'Paid' or x."IsTest" or x."Source" <> 'Online' or x."AutomatedOrderNo" is null then
    return query select false, null::bigint, null::text, null::text, null::text;
    return;
  end if;

  select * into v_order from public."AutomatedOrders" where "OrderNo" = x."AutomatedOrderNo" for update;
  if not found or coalesce(v_order."PancakeSyncStatus", '') <> 'Not Pushed' or v_order."Status" in ('Completed', 'Cancelled') then
    return query select false, null::bigint, null::text, null::text, null::text;
    return;
  end if;

  select coalesce(sum(l."Quantity" * l."Price"), 0)
         + case when v_order."FulfillmentType" = 'Delivery' then coalesce(v_order."DeliveryFee", 0) else 0 end
    into v_total
    from public."AutomatedOrderLines" l where l."OrderNo" = v_order."OrderNo";
  select coalesce(sum(p."Amount"), 0) into v_paid
    from public."AutomatedOrderPayments" p
   where p."OrderNo" = v_order."OrderNo" and coalesce(p."Method", '') not ilike 'Xendit TEST%';

  if v_total <= 0 or public._xendit_down_payment_due(v_total, v_paid) > 0 then
    return query select false, null::bigint, null::text, null::text, null::text;
    return;
  end if;

  begin
    perform public._confirm_bot_order(v_order."OrderNo", 'Xendit');
  exception when others then
    v_error := sqlerrm;
  end;

  if v_error is not null then
    -- Once only: a repeated webhook comes back here with the same reason.
    if coalesce(x."ApplyError", '') not like 'Not auto-confirmed:%' then
      update public."XenditPayments" set "ApplyError" = left('Not auto-confirmed: ' || v_error, 500) where "PaymentID" = x."PaymentID";
      begin
        perform public._telegram_send_message('Xendit: order ' || v_order."OrderNo" || ' is paid but could not be auto-confirmed. Please confirm it by hand. ' || v_error);
      exception when others then
        null;
      end;
    end if;
    return query select false, null::bigint, null::text, null::text, null::text;
    return;
  end if;

  update public."XenditPayments"
     set "AppliedIn" = 'Portal (auto-confirmed)', "ApplyError" = null
   where "PaymentID" = x."PaymentID";

  -- Same message as Confirm Order on GMA Conversations / Online Orders. No chat, or a website one: nothing to send.
  v_psid := nullif(trim(v_order."GmaPsid"), '');
  if v_psid is null or v_psid like 'web:%' then
    return query select true, null::bigint, null::text, null::text, null::text;
    return;
  end if;
  select coalesce(nullif(trim(v_order."GmaPageId"), ''), nullif(trim(c."PageId"), '')) into v_page_id
    from public."ChatbotConversations" c where c."Psid" = v_psid;
  if not found then
    return query select true, null::bigint, null::text, null::text, null::text;
    return;
  end if;

  v_text := 'Your order has been confirmed, Please see receipt for your reference. We will keep you posted on the status of your order. Any concerns please let us know :) #HFK'
    || E'\nhttps://rspetstop.com/online-order-receipt.html?order=' || v_order."OrderNo";
  insert into public."ChatbotMessages" ("Psid", "Role", "Content", "SentByUsername")
  values (v_psid, 'assistant', v_text, 'Xendit')
  returning "Id" into v_message_id;
  update public."ChatbotConversations" set "LastMessageAtUtc" = now() where "Psid" = v_psid;

  return query select true, v_message_id, v_psid, v_page_id, v_text;
end;
$$;

revoke all on function public._xendit_try_auto_confirm(uuid) from public, anon, authenticated;
grant execute on function public._xendit_try_auto_confirm(uuid) to service_role;

create or replace function public._xendit_set_confirm_message_status(p_message_id bigint, p_sent boolean, p_facebook_mid text)
returns void
language sql
security definer
set search_path = public
as $$
  update public."ChatbotMessages"
     set "DeliveryStatus" = case when p_sent then 'Sent' else 'Failed' end,
         "FacebookMessageId" = coalesce(nullif(p_facebook_mid, ''), "FacebookMessageId")
   where "Id" = p_message_id;
$$;

revoke all on function public._xendit_set_confirm_message_status(bigint, boolean, text) from public, anon, authenticated;
grant execute on function public._xendit_set_confirm_message_status(bigint, boolean, text) to service_role;

notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon'
            when has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role'
            else 'internal' end as access
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('_confirm_bot_order', 'admin_confirm_bot_order', '_xendit_try_auto_confirm', '_xendit_set_confirm_message_status')
 order by 1;
