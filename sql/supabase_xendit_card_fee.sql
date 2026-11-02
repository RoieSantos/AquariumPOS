-- Xendit: card fee on the pay page - per "in our local POS we have 5% charge for credit cards payment.. how can we
-- control it for xendit online credit card payment". Xendit's checkout fixes the amount before the customer picks
-- a method, so pay.html asks first: card (amount + fee, cards only) or everything else (no fee, no cards).
--
-- XenditSettings."CardFeePercent" is set on the Xendit Payments page (default 5, 0 = no fee and no split). It is
-- separate from the POS's CardMarkupPercent, which lives in each POS's own database.
-- The fee is worked out here, never trusted from the browser. Like POS Online Pay, only the amount comes off the
-- order: "PaidAmount" stays the order's part, and the fee is in XenditPayments."CardFee". The receipt page and the
-- Messenger receipt show both.
--
-- Run AFTER supabase_xendit_pos_walkin.sql, supabase_xendit_payment_receipt_page.sql and
-- supabase_xendit_receipt_numbers.sql. Safe to re-run. Needs the Edge Function xendit-create-invoice redeployed,
-- js/pay.js ?v=xendit4, js/xenditPayments.js ?v=xendit9 and payment-receipt.html.

alter table public."XenditSettings" add column if not exists "CardFeePercent" numeric(5, 2) not null default 5;
alter table public."XenditPayments" add column if not exists "CardFee" numeric(18, 2) not null default 0;

-- ---------------------------------------------------------------------------
-- 1. Pay page and Edge Function

create or replace function public.public_get_xendit_card_fee_percent()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select s."CardFeePercent" from public."XenditSettings" s where s."Id" = 1), 0);
$$;

grant execute on function public.public_get_xendit_card_fee_percent() to anon;

create or replace function public._xendit_set_card_fee(p_payment_id uuid, p_pay_by_card boolean)
returns table(card_fee numeric, fee_percent numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_percent numeric := public.public_get_xendit_card_fee_percent();
  v_fee numeric := 0;
begin
  if coalesce(p_pay_by_card, false) then
    update public."XenditPayments"
       set "CardFee" = round("Amount" * v_percent / 100, 2)
     where "PaymentID" = p_payment_id and "Status" = 'Creating'
    returning "CardFee" into v_fee;
  end if;
  return query select coalesce(v_fee, 0), v_percent;
end;
$$;

revoke all on function public._xendit_set_card_fee(uuid, boolean) from public, anon, authenticated;
grant execute on function public._xendit_set_card_fee(uuid, boolean) to service_role;

-- Same as supabase_xendit_payments.sql, except Xendit's amount includes the card fee and the order's part doesn't.
create or replace function public._xendit_record_invoice_status(p_invoice jsonb, p_webhook jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  x public."XenditPayments"%rowtype;
  v_status text := upper(coalesce(p_invoice ->> 'status', ''));
begin
  select * into x from public."XenditPayments"
   where "InvoiceID" = p_invoice ->> 'id' or "ExternalID" = p_invoice ->> 'external_id'
   order by ("InvoiceID" = p_invoice ->> 'id') desc nulls last
   limit 1
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Unknown invoice ' || coalesce(p_invoice ->> 'id', '?'));
  end if;

  update public."XenditPayments"
     set "LastWebhook" = p_webhook, "LastWebhookAtUtc" = now(),
         "InvoiceID" = coalesce("InvoiceID", p_invoice ->> 'id')
   where "PaymentID" = x."PaymentID";

  if v_status in ('PAID', 'SETTLED') then
    if x."Status" <> 'Paid' then
      update public."XenditPayments"
         set "Status" = 'Paid',
             "PaidAmount" = coalesce(nullif(p_invoice ->> 'paid_amount', '')::numeric - "CardFee", nullif(p_invoice ->> 'amount', '')::numeric - "CardFee", "Amount"),
             "PaymentMethod" = p_invoice ->> 'payment_method',
             "PaymentChannel" = p_invoice ->> 'payment_channel',
             "XenditPaymentRef" = coalesce(p_invoice ->> 'payment_id', p_invoice ->> 'id'),
             "PaidAtUtc" = coalesce(nullif(p_invoice ->> 'paid_at', '')::timestamptz, now())
       where "PaymentID" = x."PaymentID";
    end if;
    perform public._apply_xendit_payment(x."PaymentID");
  elsif v_status = 'EXPIRED' and x."Status" in ('Pending', 'Creating') then
    update public."XenditPayments" set "Status" = 'Expired' where "PaymentID" = x."PaymentID";
  end if;

  select * into x from public."XenditPayments" where "PaymentID" = x."PaymentID";
  return jsonb_build_object('ok', true, 'payment_id', x."PaymentID", 'status', x."Status", 'apply_status', x."ApplyStatus");
end;
$$;

revoke all on function public._xendit_record_invoice_status(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public._xendit_record_invoice_status(jsonb, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Receipts: same as before, plus the fee.

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
    || case when x."CardFee" > 0
            then E'\nCard fee: ₱' || to_char(x."CardFee", 'FM999,999,990.00') || '. Total charged: ₱' || to_char(v_amount + x."CardFee", 'FM999,999,990.00') || '.'
            else '' end
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

drop function if exists public.public_get_xendit_payment_receipt(uuid);

create or replace function public.public_get_xendit_payment_receipt(p_payment_id uuid)
returns table(receipt_no text, paid_at timestamptz, amount numeric, purpose text, paid_via text,
              xendit_reference text, is_test boolean, order_ref text, order_status text, customer_name text,
              order_total numeric, total_paid numeric, balance numeric, items jsonb, card_fee numeric)
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
    coalesce(x."ReceiptNo", x."ExternalID"),
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
    coalesce(v_items, '[]'::jsonb),
    x."CardFee";
end;
$$;

grant execute on function public.public_get_xendit_payment_receipt(uuid) to anon;

-- ---------------------------------------------------------------------------
-- 3. Xendit Payments page: the percent, and the fee on each row.

drop function if exists public.admin_get_xendit_settings(text, text);

create or replace function public.admin_get_xendit_settings(p_admin_username text, p_admin_password text)
returns table(enabled boolean, show_on_order_now boolean, updated_by text, updated_at timestamptz, pos_enabled boolean, live_mode boolean, card_fee_percent numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select s."Enabled", s."ShowOnOrderNow", s."UpdatedBy", s."UpdatedAtUtc", s."PosEnabled", s."LiveMode", s."CardFeePercent"
      from public."XenditSettings" s where s."Id" = 1;
end;
$$;

grant execute on function public.admin_get_xendit_settings(text, text) to anon;

create or replace function public.admin_set_xendit_card_fee(p_admin_username text, p_admin_password text, p_percent numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_percent is null or p_percent < 0 or p_percent > 20 then
    raise exception 'The card fee must be between 0 and 20 percent.';
  end if;
  update public."XenditSettings"
     set "CardFeePercent" = p_percent, "UpdatedBy" = p_admin_username, "UpdatedAtUtc" = now()
   where "Id" = 1;
end;
$$;

grant execute on function public.admin_set_xendit_card_fee(text, text, numeric) to anon;

drop function if exists public.admin_list_xendit_payments(text, text, text, int);

create or replace function public.admin_list_xendit_payments(p_admin_username text, p_admin_password text,
                                                            p_search text default null, p_limit int default 200)
returns table(payment_id uuid, created_at timestamptz, order_ref text, online_order_id text, purpose text,
              amount numeric, is_test boolean, status text, invoice_url text, expires_at timestamptz,
              create_error text, paid_amount numeric, payment_method text, payment_channel text, paid_at timestamptz,
              apply_status text, apply_error text, applied_in text, applied_amount numeric, external_id text,
              receipt_message_status text, receipt_no text,
              source text, pos_receipt_no text, pos_cashier text, walkin_order_id text, card_fee numeric)
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
           x."ReceiptMessageStatus", x."ReceiptNo",
           x."Source", x."PosReceiptNo", x."PosCashier", w."OrderID"::text, x."CardFee"
      from public."XenditPayments" x
      left join public."OnlineOrders" w
        on x."PosReceiptNo" is not null and w."PosReceiptNo" = x."PosReceiptNo" and w."PosWarehouseId" = x."PosWarehouseId"
     where v_search is null
        or x."OrderRef" ilike '%' || v_search || '%'
        or x."OnlineOrderID" ilike '%' || v_search || '%'
        or x."ExternalID" ilike '%' || v_search || '%'
        or x."ReceiptNo" ilike '%' || v_search || '%'
        or x."PosReceiptNo" ilike '%' || v_search || '%'
        or w."OrderID" ilike '%' || v_search || '%'
     order by x."CreatedAtUtc" desc
     limit greatest(coalesce(p_limit, 200), 1);
end;
$$;

grant execute on function public.admin_list_xendit_payments(text, text, text, int) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'setting' as section, 'Card fee percent' as item, s."CardFeePercent"::text as value
  from public."XenditSettings" s where s."Id" = 1
union all
select 'column', c.column_name::text, c.data_type::text
  from information_schema.columns c
 where c.table_schema = 'public' and c.table_name = 'XenditPayments' and c.column_name = 'CardFee';
