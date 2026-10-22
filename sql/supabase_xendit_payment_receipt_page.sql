-- Xendit payment receipt - per "can we send a receipt as well showing what they pay?".
--
-- New public page payment-receipt.html?id=<PaymentID> shows one online payment: receipt no., date paid,
-- received from, amount, what it was for (down payment / full balance of order AO-...), how it was paid
-- (GCash / Maya / card via Xendit + Xendit's reference), the order's items, total, paid to date and
-- remaining balance. The link uses the payment's random ID (uuid), so a receipt can't be found by
-- guessing an order number - that's why it can show the customer's name.
-- It acknowledges the payment; it is NOT a BIR Official Receipt / Sales Invoice (the page says so).
--
-- The automatic "Payment received" Messenger message (_xendit_claim_receipt_message, redefined below -
-- same as supabase_xendit_payment_receipt_message.sql plus one "Receipt: <link>" line) now carries the
-- link, and the Xendit Payments page has a Receipt link on every paid row.
--
-- Run AFTER supabase_xendit_payment_receipt_message.sql. Safe to re-run. No Edge Function redeploy
-- needed (the message text is built here). Needs payment-receipt.html and js/xenditPayments.js ?v=xendit5.

drop function if exists public.public_get_xendit_payment_receipt(uuid);

create or replace function public.public_get_xendit_payment_receipt(p_payment_id uuid)
returns table(receipt_no text, paid_at timestamptz, amount numeric, purpose text, paid_via text,
              xendit_reference text, is_test boolean, order_ref text, order_status text, customer_name text,
              order_total numeric, total_paid numeric, balance numeric, items jsonb)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  x public."XenditPayments"%rowtype;
  r record;
  v_items jsonb;
begin
  select * into x from public."XenditPayments" where "PaymentID" = p_payment_id and "Status" = 'Paid';
  if not found then
    return;
  end if;

  select * into r from public._xendit_resolve_order(x."OrderRef");

  if r.online_order_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(l."Description", l."ItemCode"), 'qty', l."Quantity",
                                                 'amount', coalesce(l."NetAmount", l."Quantity" * l."Price")) order by l."LineID"), '[]'::jsonb)
      into v_items from public."OnlineOrderLines" l where l."OrderID" = r.online_order_id;
  end if;
  if coalesce(jsonb_array_length(v_items), 0) = 0 and r.automated_order_no is not null then
    select coalesce(jsonb_agg(jsonb_build_object('name', l."ItemName", 'qty', l."Quantity",
                                                 'amount', l."Quantity" * l."Price") order by l."EntryNo"), '[]'::jsonb)
      into v_items from public."AutomatedOrderLines" l where l."OrderNo" = r.automated_order_no;
  end if;

  return query select
    x."ExternalID",
    coalesce(x."PaidAtUtc", x."CreatedAtUtc"),
    coalesce(x."PaidAmount", x."Amount"),
    x."Purpose",
    public._xendit_channel_label(x."PaymentChannel", x."PaymentMethod") || ' via Xendit',
    coalesce(x."XenditPaymentRef", x."InvoiceID"),
    x."IsTest",
    x."OrderRef",
    r.order_status,
    r.customer_name,
    r.total,
    r.amount_paid,
    r.balance,
    coalesce(v_items, '[]'::jsonb);
end;
$$;

grant execute on function public.public_get_xendit_payment_receipt(uuid) to anon;

-- Same as supabase_xendit_payment_receipt_message.sql, plus the "Receipt: <link>" line.
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
            else E'\nRemaining balance: ₱' || to_char(r.balance, 'FM999,999,990.00') || '.' end
    || E'\n\n🧾 Receipt: https://rspetstop.com/payment-receipt.html?id=' || x."PaymentID"::text;

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

notify pgrst, 'reload schema';

-- Verification - one result: the functions, and a sample receipt for the latest paid payment.
select 'function' as section, p.proname::text as item,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon' else 'service_role only' end as value
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('public_get_xendit_payment_receipt', '_xendit_claim_receipt_message')
union all
select 'latest receipt', rc.receipt_no, rc.purpose || ' ' || rc.amount::text || ' - ' || rc.paid_via || ' - balance ' || rc.balance::text
  from (select x."PaymentID" from public."XenditPayments" x where x."Status" = 'Paid' order by x."PaidAtUtc" desc nulls last limit 1) last
  cross join lateral public.public_get_xendit_payment_receipt(last."PaymentID") rc;
