-- Xendit: tell the customer in Messenger when their online payment lands - per "is it possible that in
-- the conversation they can pay the order?" (staff "Pay link" button on the Conversations order card +
-- this automatic "payment received" message).
--
-- xendit-webhook, after a paid invoice is Applied to its order, calls _xendit_claim_receipt_message:
--   - only for an order with a Messenger chat (AutomatedOrders.GmaPsid - Conversations "+ New Order" and
--     Alice's bot orders), once per payment (ReceiptMessageAtUtc is the claim, so a resent webhook
--     never messages twice);
--   - writes the message into the conversation thread (ChatbotMessages, Role 'assistant', SentByUsername
--     'Xendit' - the same way the bot logs its own replies, so it doesn't pause the bot) and returns it;
--   - TEST payments are never sent to Messenger (a test order may sit on a real customer's chat): the
--     message is saved with a "[TEST - not sent to customer]" prefix and DeliveryStatus 'Not sent (test)'
--     so staff can see exactly what the customer would get.
-- The Edge Function then sends it (normal reply; outside Facebook's 24h window it retries with the
-- POST_PURCHASE_UPDATE tag) and records Sent / Failed on the message and the payment
-- (_xendit_set_receipt_message_status).
-- A payment applied later by "Retry" on the Xendit Payments page gets no automatic message.
--
-- Run AFTER supabase_xendit_payments.sql. Safe to re-run. Needs xendit-webhook redeployed and
-- xendit-payments.html with js/xenditPayments.js ?v=xendit4.

alter table public."XenditPayments" add column if not exists "ReceiptMessageId" bigint;
alter table public."XenditPayments" add column if not exists "ReceiptMessageAtUtc" timestamptz;
alter table public."XenditPayments" add column if not exists "ReceiptMessageStatus" text; -- Sending / Sent / Failed: ... / Not sent (test) / No chat

-- Xendit's channel code -> what a customer calls it.
create or replace function public._xendit_channel_label(p_channel text, p_method text)
returns text
language sql
immutable
as $$
  select case upper(coalesce(nullif(p_channel, ''), p_method, ''))
    when 'GCASH' then 'GCash'
    when 'PAYMAYA' then 'Maya'
    when 'MAYA' then 'Maya'
    when 'GRABPAY' then 'GrabPay'
    when 'SHOPEEPAY' then 'ShopeePay'
    when 'QRPH' then 'QR Ph'
    when 'CREDIT_CARD' then 'card'
    when '' then 'online payment'
    else initcap(replace(lower(coalesce(nullif(p_channel, ''), p_method)), '_', ' '))
  end;
$$;

drop function if exists public._xendit_claim_receipt_message(uuid);

create or replace function public._xendit_claim_receipt_message(p_payment_id uuid)
returns table(psid text, page_id text, message_id bigint, message text, is_test boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  x public."XenditPayments"%rowtype;
  v_psid text;
  v_page_id text;
  r record;
  v_amount numeric;
  v_text text;
  v_message_id bigint;
begin
  select * into x from public."XenditPayments" where "PaymentID" = p_payment_id for update;
  if not found or x."Status" <> 'Paid' or x."ApplyStatus" <> 'Applied' or x."ReceiptMessageAtUtc" is not null
     or x."AutomatedOrderNo" is null then
    return;
  end if;

  select nullif(trim(a."GmaPsid"), ''), nullif(trim(a."GmaPageId"), '') into v_psid, v_page_id
    from public."AutomatedOrders" a where a."OrderNo" = x."AutomatedOrderNo";
  if v_psid is null or not exists (select 1 from public."ChatbotConversations" c where c."Psid" = v_psid) then
    update public."XenditPayments" set "ReceiptMessageAtUtc" = now(), "ReceiptMessageStatus" = 'No chat'
     where "PaymentID" = x."PaymentID";
    return;
  end if;
  select coalesce(v_page_id, nullif(trim(c."PageId"), '')) into v_page_id
    from public."ChatbotConversations" c where c."Psid" = v_psid;

  select * into r from public._xendit_resolve_order(x."OrderRef");
  v_amount := coalesce(x."PaidAmount", x."Amount");

  v_text := case when x."IsTest" then '[TEST - not sent to customer] ' else '' end
    || '✅ Payment received - thank you! We got your ₱' || to_char(v_amount, 'FM999,999,990.00')
    || ' ' || public._xendit_channel_label(x."PaymentChannel", x."PaymentMethod")
    || ' payment (' || lower(x."Purpose") || ') for order ' || x."OrderRef" || '.'
    || case when coalesce(r.balance, 0) <= 0
            then E'\nYour order is now fully paid. 🎉'
            else E'\nRemaining balance: ₱' || to_char(r.balance, 'FM999,999,990.00') || '.' end;

  insert into public."ChatbotMessages" ("Psid", "Role", "Content", "SentByUsername", "DeliveryStatus")
  values (v_psid, 'assistant', v_text, 'Xendit', case when x."IsTest" then 'Not sent (test)' end)
  returning "Id" into v_message_id;

  update public."ChatbotConversations" set "LastMessageAtUtc" = now() where "Psid" = v_psid;

  update public."XenditPayments"
     set "ReceiptMessageAtUtc" = now(), "ReceiptMessageId" = v_message_id,
         "ReceiptMessageStatus" = case when x."IsTest" then 'Not sent (test)' else 'Sending' end
   where "PaymentID" = x."PaymentID";

  return query select v_psid, v_page_id, v_message_id, v_text, x."IsTest";
end;
$$;

revoke all on function public._xendit_claim_receipt_message(uuid) from public, anon, authenticated;
grant execute on function public._xendit_claim_receipt_message(uuid) to service_role;

drop function if exists public._xendit_set_receipt_message_status(uuid, text, text);

create or replace function public._xendit_set_receipt_message_status(p_payment_id uuid, p_status text, p_facebook_mid text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_message_id bigint;
begin
  update public."XenditPayments" set "ReceiptMessageStatus" = left(p_status, 300)
   where "PaymentID" = p_payment_id
  returning "ReceiptMessageId" into v_message_id;
  if v_message_id is not null then
    update public."ChatbotMessages"
       set "DeliveryStatus" = case when p_status = 'Sent' then 'Sent' else 'Failed' end,
           "FacebookMessageId" = coalesce(nullif(p_facebook_mid, ''), "FacebookMessageId")
     where "Id" = v_message_id;
  end if;
end;
$$;

revoke all on function public._xendit_set_receipt_message_status(uuid, text, text) from public, anon, authenticated;
grant execute on function public._xendit_set_receipt_message_status(uuid, text, text) to service_role;

-- Xendit Payments page: + receipt_message_status (return type changes, so drop first).
drop function if exists public.admin_list_xendit_payments(text, text, text, int);

create or replace function public.admin_list_xendit_payments(p_admin_username text, p_admin_password text,
                                                            p_search text default null, p_limit int default 200)
returns table(payment_id uuid, created_at timestamptz, order_ref text, online_order_id text, purpose text,
              amount numeric, is_test boolean, status text, invoice_url text, expires_at timestamptz,
              create_error text, paid_amount numeric, payment_method text, payment_channel text, paid_at timestamptz,
              apply_status text, apply_error text, applied_in text, applied_amount numeric, external_id text,
              receipt_message_status text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select x."PaymentID", x."CreatedAtUtc", x."OrderRef", x."OnlineOrderID", x."Purpose", x."Amount", x."IsTest",
           x."Status", x."InvoiceUrl", x."ExpiresAtUtc", x."CreateError", x."PaidAmount", x."PaymentMethod",
           x."PaymentChannel", x."PaidAtUtc", x."ApplyStatus", x."ApplyError", x."AppliedIn", x."AppliedAmount", x."ExternalID",
           x."ReceiptMessageStatus"
      from public."XenditPayments" x
     where v_search is null
        or x."OrderRef" ilike '%' || v_search || '%'
        or x."OnlineOrderID" ilike '%' || v_search || '%'
        or x."ExternalID" ilike '%' || v_search || '%'
     order by x."CreatedAtUtc" desc
     limit greatest(coalesce(p_limit, 200), 1);
end;
$$;

grant execute on function public.admin_list_xendit_payments(text, text, text, int) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'column' as section, column_name::text as item, 'ok' as value
  from information_schema.columns
 where table_schema = 'public' and table_name = 'XenditPayments' and column_name like 'ReceiptMessage%'
union all
select 'function', p.proname::text,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon'
            when has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role only'
            else 'internal' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('_xendit_claim_receipt_message', '_xendit_set_receipt_message_status', 'admin_list_xendit_payments');
