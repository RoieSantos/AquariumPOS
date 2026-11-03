-- Vic / Alice: take an order end to end with Xendit - per "can aibot now do end to end transaction with this
-- xendit?". The bot could only create an order after a payment screenshot, but a pay link needs an order first.
-- When online payment is on, create_order with pay_online now saves the order unpaid and returns the pay link.
--
--   - AutomatedOrders."AwaitingOnlinePaymentSinceUtc" marks those orders. Conversations shows "Waiting for online
--     payment" on them. Draft orders hold no stock: the ledger and serials only start from Online Orders.
--   - Reminder: one Messenger message, 12 hours after the order. Website chats get none.
--   - Auto-cancel: 48 hours after the order, if nothing at all was paid. Not while a checkout is still open, within
--     12 hours of the customer's last message, or while the chat is escalated: the next run tries again.
--   - Any payment, manual or online, stops both. So does staff confirming the order.
--   - A custom item (a line with no ItemCode) never auto-confirms, whoever made the order: payment is recorded, the
--     reason shows on the Xendit Payments row and staff get a Telegram alert, then they confirm it.
--
-- Run AFTER supabase_xendit_auto_confirm.sql, supabase_gma_order_delivery_fee.sql and supabase_chatbot_followups.sql.
-- Safe to re-run. If supabase_gma_order_delivery_fee.sql is ever re-run, run this one again afterwards.
-- Needs chatbot-engine.ts (every function that uses it) and chatbot-followup-dispatcher redeployed, and
-- js/gmaConversations.js ?v=unpaid1.

alter table public."AutomatedOrders" add column if not exists "AwaitingOnlinePaymentSinceUtc" timestamptz;

comment on column public."AutomatedOrders"."AwaitingOnlinePaymentSinceUtc" is 'Set when the bot saved this order unpaid with a Xendit pay link. Drives the reminder and auto-cancel (_xendit_unpaid_orders_tick).';

create index if not exists "IX_AutomatedOrders_AwaitingOnlinePayment"
  on public."AutomatedOrders" ("AwaitingOnlinePaymentSinceUtc")
  where "AwaitingOnlinePaymentSinceUtc" is not null and "Status" = 'New';

-- ---------------------------------------------------------------------------
-- 1. Can customers really pay online right now? Same test as pay_link_ok in _chatbot_order_payment_status.

create or replace function public._xendit_online_payment_open()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select s."Enabled" and s."LiveMode" from public."XenditSettings" s where s."Id" = 1), false);
$$;

revoke all on function public._xendit_online_payment_open() from public, anon, authenticated;
grant execute on function public._xendit_online_payment_open() to service_role;

-- ---------------------------------------------------------------------------
-- 2. Still a bot order with nothing paid and nobody having confirmed it?

create or replace function public._xendit_unpaid_order_open(p_order_no text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public."AutomatedOrders" o
     where o."OrderNo" = p_order_no
       and o."AwaitingOnlinePaymentSinceUtc" is not null
       and o."Status" = 'New'
       and o."PancakeSyncStatus" = 'Not Pushed'
       and not exists (select 1 from public."AutomatedOrderPayments" p where p."OrderNo" = o."OrderNo")
       and not exists (select 1 from public."XenditPayments" x where x."AutomatedOrderNo" = o."OrderNo" and x."Status" = 'Paid')
  );
$$;

revoke all on function public._xendit_unpaid_order_open(text) from public, anon, authenticated;
grant execute on function public._xendit_unpaid_order_open(text) to service_role;

-- A held reminder (bot off hours) can go out later: chatbot-followup-dispatcher checks this just before sending.
-- True for any other order's reminder, so older PendingOrder follow-ups behave as before.
create or replace function public._xendit_unpaid_reminder_still_needed(p_order_no text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._xendit_unpaid_order_open(p_order_no)
      or not exists (select 1 from public."AutomatedOrders" o where o."OrderNo" = p_order_no and o."AwaitingOnlinePaymentSinceUtc" is not null);
$$;

revoke all on function public._xendit_unpaid_reminder_still_needed(text) from public, anon, authenticated;
grant execute on function public._xendit_unpaid_reminder_still_needed(text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. Reminder and auto-cancel. chatbot-followup-dispatcher runs this every 15 minutes.

create or replace function public._xendit_unpaid_orders_tick()
returns table(reminders int, cancelled int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c_reminder_after constant interval := interval '12 hours';
  c_cancel_after constant interval := interval '48 hours';
  c_quiet_for constant interval := interval '12 hours';
  v_order public."AutomatedOrders"%rowtype;
  v_psid text;
  v_reminders int := 0;
  v_cancelled int := 0;
begin
  for v_order in
    select o.* from public."AutomatedOrders" o
     where o."AwaitingOnlinePaymentSinceUtc" <= now() - c_reminder_after
       and o."Status" = 'New'
       and o."PancakeSyncStatus" = 'Not Pushed'
     order by o."AwaitingOnlinePaymentSinceUtc"
     limit 100
     for update skip locked
  loop
    continue when not public._xendit_unpaid_order_open(v_order."OrderNo");

    if v_order."AwaitingOnlinePaymentSinceUtc" <= now() - c_cancel_after then
      continue when exists (
        select 1 from public."XenditPayments" x
         where x."AutomatedOrderNo" = v_order."OrderNo"
           and ((x."Status" = 'Pending' and x."ExpiresAtUtc" > now())
             or (x."Status" = 'Creating' and x."CreatedAtUtc" > now() - interval '1 hour'))
      );
      continue when exists (
        select 1 from public."ChatbotConversations" c
         where c."Psid" = v_order."GmaPsid"
           and (c."Status" = 'Escalated' or c."LastCustomerMessageAtUtc" > now() - c_quiet_for)
      );

      update public."AutomatedOrders"
         set "Status" = 'Cancelled',
             "Notes" = concat_ws(E'\n', nullif("Notes", ''), '[Auto-cancelled: no online payment within 48 hours]'),
             "UpdatedBy" = 'Xendit',
             "UpdatedAtUtc" = now()
       where "OrderNo" = v_order."OrderNo";
      -- A reminder held back by bot hours must not go out for a cancelled order.
      update public."ChatbotFollowUps"
         set "Status" = 'Cancelled'
       where "RelatedOrderNo" = v_order."OrderNo" and "Status" = 'Pending';
      v_cancelled := v_cancelled + 1;

    elsif v_order."PaymentReminderSentAtUtc" is null then
      v_psid := nullif(trim(v_order."GmaPsid"), '');
      if v_psid is not null and v_psid not like 'web:%'
         and exists (select 1 from public."ChatbotConversations" c where c."Psid" = v_psid) then
        insert into public."ChatbotFollowUps" ("Psid", "FollowUpType", "DueAtUtc", "RelatedOrderNo", "Reason")
        values (
          v_psid, 'PendingOrder', now(), v_order."OrderNo",
          'Order ' || v_order."OrderNo" || ' (total PHP ' || to_char(v_order."EstimatedTotal", 'FM999,999,990.00')
            || ') is saved but not paid yet. Remind the customer gently, and say it is cancelled automatically if still unpaid 2 days after it was placed. They can pay here: https://www.rspetstop.com/pay.html?order='
            || v_order."OrderNo"
        );
        update public."AutomatedOrders" set "PaymentReminderSentAtUtc" = now() where "OrderNo" = v_order."OrderNo";
        v_reminders := v_reminders + 1;
      end if;
    end if;
  end loop;

  return query select v_reminders, v_cancelled;
end;
$$;

revoke all on function public._xendit_unpaid_orders_tick() from public, anon, authenticated;
grant execute on function public._xendit_unpaid_orders_tick() to service_role;

-- ---------------------------------------------------------------------------
-- 4. _xendit_try_auto_confirm (supabase_xendit_auto_confirm.sql) + custom items wait for staff.

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

  -- This file: a custom build's spec and price need a person to check them.
  if exists (select 1 from public."AutomatedOrderLines" l where l."OrderNo" = v_order."OrderNo" and l."ItemCode" is null) then
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

-- ---------------------------------------------------------------------------
-- 5. admin_list_automated_orders_by_gma_conversation (supabase_gma_order_delivery_fee.sql) + awaiting_online_payment.

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
  delivery_fee numeric,
  awaiting_online_payment boolean
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
      coalesce(o."DeliveryFee", 0)::numeric,
      o."AwaitingOnlinePaymentSinceUtc" is not null and public._xendit_unpaid_order_open(o."OrderNo")
    from public."AutomatedOrders" o
    where o."GmaPsid" = trim(p_psid)
      and (p_page_id is null or trim(p_page_id) = '' or o."GmaPageId" = trim(p_page_id))
    order by o."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_automated_orders_by_gma_conversation(text, text, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon'
            when has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role'
            else 'internal' end as access,
       (select count(*) from public."AutomatedOrders" where "AwaitingOnlinePaymentSinceUtc" is not null) as orders_awaiting_payment
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('_xendit_online_payment_open', '_xendit_unpaid_order_open', '_xendit_unpaid_reminder_still_needed', '_xendit_unpaid_orders_tick', '_xendit_try_auto_confirm', 'admin_list_automated_orders_by_gma_conversation')
 order by 1;
