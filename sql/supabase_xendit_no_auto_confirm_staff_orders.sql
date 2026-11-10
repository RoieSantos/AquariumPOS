-- Xendit: don't auto-confirm orders made by staff - per "if the order is created by the staff let the staff do
-- the confirmation and dont auto confirm it for now".
--
-- A pay-link payment still auto-confirms orders the customer made themselves: Vic, Alice and Order Now
-- (AutomatedOrders."CreatedBy" in 'Vic' / 'Alice' / 'Order Now'; the custom aquarium Create Order goes through
-- Order Now). Anything else (Conversations order card, Online Orders -> + New Order, any staff username) is staff-made:
-- the payment is still recorded, "Not auto-confirmed: created by staff ..." shows on the Xendit Payments row and staff
-- get one Telegram alert, then they click Confirm Order as usual.
--
-- Only _xendit_try_auto_confirm changes; it is otherwise the same as supabase_xendit_bot_pay_online.sql (custom-item
-- rule kept). To turn auto-confirm back on for staff orders, re-run supabase_xendit_bot_pay_online.sql.
--
-- Run AFTER supabase_xendit_bot_pay_online.sql and supabase_bot_order_created_by_keep.sql. Safe to re-run.
-- No Edge Function redeploy needed (xendit-webhook already handles "not confirmed").

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

  -- This file: an order made by staff is confirmed by staff, not by the payment.
  if coalesce(nullif(trim(v_order."CreatedBy"), ''), nullif(trim(v_order."UpdatedBy"), ''), '') not in ('Vic', 'Alice', 'Order Now') then
    v_error := 'created by staff (' || coalesce(nullif(trim(v_order."CreatedBy"), ''), nullif(trim(v_order."UpdatedBy"), ''), 'unknown')
               || '), so staff confirm it.';
  -- A custom build's spec and price need a person to check them.
  elsif exists (select 1 from public."AutomatedOrderLines" l where l."OrderNo" = v_order."OrderNo" and l."ItemCode" is null) then
    v_error := 'it has a custom item, so staff need to review it.';
  else
    begin
      perform public._confirm_bot_order(v_order."OrderNo", 'Xendit');
    exception when others then
      v_error := sqlerrm;
    end;
  end if;

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

-- Check: should show staff_orders_skip = true.
select p.proname as function_name,
       pg_get_functiondef(p.oid) like '%created by staff%' as staff_orders_skip
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = '_xendit_try_auto_confirm';
