-- Xendit online payments (test mode first) - per "help me implement xendit .. right now its on approval
-- stage but i want it to get moving and create a testing environment for now so when its approved we
-- are ready to go".
--
-- Flow (Xendit Invoice API - one hosted checkout page with GCash, Maya, cards, QR Ph, banks...):
-- PORTAL ONLY - per "we are not using pancake and solely using portal now": a Xendit payment is only ever
-- written to the portal (AutomatedOrderPayments + Online Orders Amount Paid / Balance), never to Pancake.
-- An old Pancake-synced online order can't be paid online (pay.html says to contact us).
--
--   1. Customer opens pay.html?order=AO-00012. The page reads the
--      order's balance via public_get_order_for_online_payment and offers "50% down payment" (when
--      less than half is paid) and "Full balance".
--   2. The page calls the Edge Function xendit-create-invoice. It calls _xendit_prepare_invoice here
--      (amount worked out HERE from the order - never trusted from the browser), creates the invoice
--      at Xendit with the secret key, saves the invoice ID / URL (_xendit_set_invoice) and sends the
--      customer to Xendit's checkout page.
--   3. Xendit calls the Edge Function xendit-webhook when the invoice is paid / expires. It checks the
--      callback token, re-reads the invoice from Xendit (never trusts the posted body alone) and calls
--      _xendit_record_invoice_status, which marks the row Paid and applies it to the order once:
--        - confirmed portal AO- order -> AutomatedOrderPayments + Online Orders Amount Paid / Balance
--        - AO- draft (not confirmed)  -> AutomatedOrderPayments (Confirm Order carries them over)
--      Method = 'Xendit <channel>' (e.g. 'Xendit GCASH') - Xendit is its own payment method, not GCash:
--      the money lands in the Xendit balance, not the shop's GCash account.
--      If applying fails the payment stays Paid with ApplyStatus 'Failed' + the error; "Retry" on the
--      Xendit Payments page re-applies it.
--
-- TEST MODE (secret key xnd_development_...): every invoice is stored with IsTest = true and recorded
-- with Method 'Xendit TEST <channel>' / Reference '[TEST] ...', so test payments are easy to spot and
-- delete from the order card afterwards.
-- Going live = swap the two Edge Function secrets to the live key / live callback token - nothing here
-- changes.
--
-- MASTER SWITCH - XenditSettings."Enabled" (default OFF, ticked on the Xendit Payments page). While it is
-- off the code can sit live on the website safely: pay.html tells customers online payment isn't
-- available yet, and _xendit_prepare_invoice refuses to make an invoice - except for a logged-in super
-- user (portal session in the same browser), so staff can test before switching it on. The webhook
-- always works (a payment already taken must still be recorded).
-- The "Pay online" button on the Order Now confirmation needs BOTH Enabled and ShowOnOrderNow.
--
-- Run AFTER supabase_bot_orders_portal_confirm.sql and supabase_delivery_assign_automated_order_search.sql.
-- Safe to re-run.
-- Needs the Edge Functions xendit-create-invoice + xendit-webhook deployed, and pay.html,
-- xendit-payments.html, order-now.html (orderNow.js v=xendit1).

-- ---------------------------------------------------------------------------
-- 0. Tables

create table if not exists public."XenditSettings" (
  "Id" int primary key default 1 check ("Id" = 1),
  "ShowOnOrderNow" boolean not null default false,  -- "Pay online" button on the Order Now confirmation
  "UpdatedBy" text,
  "UpdatedAtUtc" timestamptz
);
alter table public."XenditSettings" add column if not exists "Enabled" boolean not null default false; -- master switch
insert into public."XenditSettings" ("Id") values (1) on conflict ("Id") do nothing;

alter table public."XenditSettings" enable row level security;
revoke all on public."XenditSettings" from anon, authenticated;

create table if not exists public."XenditPayments" (
  "PaymentID" uuid primary key default gen_random_uuid(),
  "ExternalID" text not null unique,          -- sent to Xendit as external_id
  "OrderRef" text not null,                   -- what the customer opened: AO-xxxxx or the Online Order ID
  "AutomatedOrderNo" text,
  "OnlineOrderID" text,
  "Purpose" text not null,                    -- 'Down payment' / 'Full balance'
  "Amount" numeric(18, 2) not null,
  "IsTest" boolean not null,
  "Status" text not null default 'Creating',  -- Creating / Pending / Paid / Expired / Failed
  "InvoiceID" text unique,
  "InvoiceUrl" text,
  "ExpiresAtUtc" timestamptz,
  "CreateError" text,
  "PaidAmount" numeric(18, 2),
  "PaymentMethod" text,                       -- Xendit's payment_method (EWALLET, CREDIT_CARD, QR_CODE...)
  "PaymentChannel" text,                      -- Xendit's payment_channel (GCASH, PAYMAYA, BPI...)
  "XenditPaymentRef" text,                    -- Xendit's payment_id
  "PaidAtUtc" timestamptz,
  "ApplyStatus" text not null default 'Pending', -- Pending / Applied / Failed / Not applied (test)
  "ApplyError" text,
  "AppliedIn" text,
  "AppliedAmount" numeric(18, 2),
  "AppliedAtUtc" timestamptz,
  "LastWebhook" jsonb,
  "LastWebhookAtUtc" timestamptz,
  "CreatedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_XenditPayments_OrderRef" on public."XenditPayments" ("OrderRef");
create index if not exists "IX_XenditPayments_AutomatedOrderNo" on public."XenditPayments" ("AutomatedOrderNo");
create index if not exists "IX_XenditPayments_OnlineOrderID" on public."XenditPayments" ("OnlineOrderID");
create index if not exists "IX_XenditPayments_CreatedAtUtc" on public."XenditPayments" ("CreatedAtUtc" desc);

alter table public."XenditPayments" enable row level security;
revoke all on public."XenditPayments" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Resolve an order reference -> AO number / online order / totals

create or replace function public._xendit_resolve_order(p_ref text)
returns table(order_ref text, automated_order_no text, online_order_id text, order_status text,
              is_cancelled boolean, is_portal boolean, total numeric, amount_paid numeric, balance numeric,
              customer_name text, customer_phone text, customer_email text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_ref text := upper(trim(coalesce(p_ref, '')));
  v_ao public."AutomatedOrders"%rowtype;
  v_has_ao boolean := false;
  v_oo public."OnlineOrders"%rowtype;
  v_has_oo boolean := false;
  v_paid numeric;
  v_total numeric;
  v_status text;
  -- Paid at Xendit but not on the order yet (failed / still applying) - counted as paid so the
  -- customer is never asked to pay it again.
  v_unapplied numeric;
begin
  if v_ref = '' then
    return;
  end if;

  select * into v_ao from public."AutomatedOrders" where upper("OrderNo") = v_ref;
  v_has_ao := found;
  if v_has_ao then
    select * into v_oo from public."OnlineOrders"
     where "OrderID" = coalesce(nullif(trim(v_ao."PancakeReceiptNo"), ''), v_ao."OrderNo");
    v_has_oo := found;
  else
    select * into v_oo from public."OnlineOrders" where "OrderID" = trim(p_ref);
    v_has_oo := found;
    if not v_has_oo then
      return;
    end if;
    select * into v_ao from public."AutomatedOrders" where "PancakeReceiptNo" = v_oo."OrderID" limit 1;
    v_has_ao := found;
  end if;

  select coalesce(sum(coalesce(x."PaidAmount", x."Amount")), 0) into v_unapplied
    from public."XenditPayments" x
   where x."Status" = 'Paid' and x."ApplyStatus" in ('Pending', 'Failed')
     and (x."AutomatedOrderNo" = v_ao."OrderNo" or x."OnlineOrderID" = v_oo."OrderID");

  if v_has_oo then
    v_paid := coalesce(v_oo."AmountPaid", 0);
    v_total := coalesce(v_oo."AmountPaid", 0) + coalesce(v_oo."Balance", 0);
    v_status := v_oo."Status";
  else
    v_paid := coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = v_ao."OrderNo"), 0);
    v_total := coalesce(public._automated_order_total(v_ao."OrderNo"), 0);
    v_status := v_ao."Status";
  end if;
  v_paid := v_paid + v_unapplied;

  return query select
    case when v_has_ao then v_ao."OrderNo" else v_oo."OrderID" end::text,
    case when v_has_ao then v_ao."OrderNo" end::text,
    case when v_has_oo then v_oo."OrderID" end::text,
    v_status::text,
    lower(trim(coalesce(v_status, ''))) in ('canceled', 'cancelled', 'cancel', 'returned', 'returning'),
    case when v_has_oo then public._is_portal_only_online_order(v_oo."OrderID") else true end,
    round(v_total, 2),
    round(v_paid, 2),
    round(greatest(v_total - v_paid, 0), 2),
    coalesce(nullif(trim(v_ao."CustomerName"), ''), v_oo."CustomerName")::text,
    coalesce(nullif(trim(v_ao."CustomerPhone"), ''), v_oo."ShippingPhone")::text,
    nullif(trim(coalesce(v_ao."CustomerEmail", '')), '')::text;
end;
$$;

revoke all on function public._xendit_resolve_order(text) from public, anon, authenticated;

-- 50% down payment still owed (0 once at least half is paid).
create or replace function public._xendit_down_payment_due(p_total numeric, p_paid numeric)
returns numeric
language sql
immutable
as $$
  select greatest(ceil(coalesce(p_total, 0) / 2) - coalesce(p_paid, 0), 0)::numeric;
$$;

-- ---------------------------------------------------------------------------
-- 2. Public: what pay.html shows. Deliberately no customer name / phone / address - the page is
--    reachable by anyone who knows (or guesses) an order number.

drop function if exists public.public_get_order_for_online_payment(text);

create or replace function public.public_get_order_for_online_payment(p_order_ref text)
returns table(order_ref text, online_order_id text, order_status text, total numeric, amount_paid numeric,
              balance numeric, down_payment_due numeric, can_pay boolean, reason text, items jsonb,
              last_payment_status text, last_payment_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  r record;
  v_items jsonb;
  v_reason text;
  v_last record;
begin
  select * into r from public._xendit_resolve_order(p_order_ref);
  if r.order_ref is null then
    return;
  end if;

  if r.online_order_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(l."Description", l."ItemCode"), 'qty', l."Quantity") order by l."LineID"), '[]'::jsonb)
      into v_items from public."OnlineOrderLines" l where l."OrderID" = r.online_order_id;
  end if;
  if coalesce(jsonb_array_length(v_items), 0) = 0 and r.automated_order_no is not null then
    select coalesce(jsonb_agg(jsonb_build_object('name', l."ItemName", 'qty', l."Quantity") order by l."EntryNo"), '[]'::jsonb)
      into v_items from public."AutomatedOrderLines" l where l."OrderNo" = r.automated_order_no;
  end if;

  v_reason := case
    when r.is_cancelled then 'This order is ' || r.order_status || ' and can''t be paid online.'
    when not r.is_portal then 'This order can''t be paid online - please contact us to pay.'
    when r.total <= 0 then 'This order has no total yet - please wait for us to confirm it.'
    when r.balance <= 0 then 'This order is fully paid. Thank you!'
  end;

  select x."Status", coalesce(x."PaidAtUtc", x."CreatedAtUtc") as at into v_last
    from public."XenditPayments" x
   where x."OrderRef" = r.order_ref and x."Status" <> 'Creating'
   order by x."CreatedAtUtc" desc limit 1;

  return query select r.order_ref, r.online_order_id, r.order_status, r.total, r.amount_paid, r.balance,
    case when v_reason is null then least(public._xendit_down_payment_due(r.total, r.amount_paid), r.balance) else 0 end,
    v_reason is null, v_reason, coalesce(v_items, '[]'::jsonb),
    v_last."Status"::text, v_last.at;
end;
$$;

grant execute on function public.public_get_order_for_online_payment(text) to anon;

drop function if exists public.public_get_xendit_settings();

create or replace function public.public_get_xendit_settings()
returns table(enabled boolean, show_on_order_now boolean)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(s."Enabled", false), coalesce(s."Enabled" and s."ShowOnOrderNow", false)
    from (select 1) one
    left join public."XenditSettings" s on s."Id" = 1;
$$;

grant execute on function public.public_get_xendit_settings() to anon;

-- ---------------------------------------------------------------------------
-- 3. Edge Function only (service role): prepare / save an invoice

drop function if exists public._xendit_prepare_invoice(text, text, boolean);
drop function if exists public._xendit_prepare_invoice(text, text, boolean, text, text);

-- p_staff_username / p_staff_password: the portal login of a super user testing while Xendit is switched
-- off (null for customers).
create or replace function public._xendit_prepare_invoice(p_order_ref text, p_purpose text, p_is_test boolean,
                                                         p_staff_username text default null, p_staff_password text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r record;
  v_purpose text := case when lower(trim(coalesce(p_purpose, ''))) like 'down%' then 'Down payment' else 'Full balance' end;
  v_amount numeric;
  v_existing public."XenditPayments"%rowtype;
  v_id uuid := gen_random_uuid();
  v_external text;
  v_items jsonb;
begin
  if not coalesce((select "Enabled" from public."XenditSettings" where "Id" = 1), false)
     and not (p_staff_username is not null and public.is_admin_authorized(p_staff_username, p_staff_password)) then
    raise exception 'Online payment is not available yet.';
  end if;

  select * into r from public._xendit_resolve_order(p_order_ref);
  if r.order_ref is null then
    raise exception 'Order % was not found.', p_order_ref;
  end if;
  if r.is_cancelled then
    raise exception 'Order % is % and can''t be paid online.', r.order_ref, r.order_status;
  end if;
  if not r.is_portal then
    raise exception 'Order % is an old Pancake order and can''t be paid online - please contact us to pay.', r.order_ref;
  end if;
  if r.balance <= 0 then
    raise exception 'Order % has nothing left to pay.', r.order_ref;
  end if;

  v_amount := case when v_purpose = 'Down payment'
                   then least(public._xendit_down_payment_due(r.total, r.amount_paid), r.balance)
                   else r.balance end;
  if v_amount <= 0 then
    raise exception 'The down payment for % is already paid - choose Full balance.', r.order_ref;
  end if;

  -- Same order, purpose, amount and mode with an open invoice -> send the customer back to it instead
  -- of making a second invoice they might pay as well.
  select * into v_existing from public."XenditPayments" x
   where x."OrderRef" = r.order_ref and x."Purpose" = v_purpose and x."Amount" = v_amount
     and x."IsTest" = coalesce(p_is_test, true) and x."Status" = 'Pending'
     and x."InvoiceUrl" is not null and x."ExpiresAtUtc" > now() + interval '10 minutes'
   order by x."CreatedAtUtc" desc limit 1;
  if found then
    return jsonb_build_object('reuse', true, 'payment_id', v_existing."PaymentID", 'invoice_url', v_existing."InvoiceUrl",
                              'amount', v_existing."Amount");
  end if;

  v_external := 'RSPS-' || r.order_ref || '-' || left(replace(v_id::text, '-', ''), 8);

  insert into public."XenditPayments" ("PaymentID", "ExternalID", "OrderRef", "AutomatedOrderNo", "OnlineOrderID",
                                       "Purpose", "Amount", "IsTest")
  values (v_id, v_external, r.order_ref, r.automated_order_no, r.online_order_id, v_purpose, v_amount, coalesce(p_is_test, true));

  return jsonb_build_object(
    'reuse', false,
    'payment_id', v_id,
    'external_id', v_external,
    'order_ref', r.order_ref,
    'purpose', v_purpose,
    'amount', v_amount,
    'total', r.total,
    'balance', r.balance,
    'customer_name', r.customer_name,
    'customer_phone', r.customer_phone,
    'customer_email', r.customer_email);
end;
$$;

revoke all on function public._xendit_prepare_invoice(text, text, boolean, text, text) from public, anon, authenticated;
grant execute on function public._xendit_prepare_invoice(text, text, boolean, text, text) to service_role;

drop function if exists public._xendit_set_invoice(uuid, text, text, timestamptz, text);

create or replace function public._xendit_set_invoice(p_payment_id uuid, p_invoice_id text, p_invoice_url text,
                                                     p_expires_at timestamptz, p_error text)
returns void
language sql
security definer
set search_path = public
as $$
  update public."XenditPayments"
     set "InvoiceID" = nullif(p_invoice_id, ''),
         "InvoiceUrl" = nullif(p_invoice_url, ''),
         "ExpiresAtUtc" = p_expires_at,
         "Status" = case when nullif(p_error, '') is null then 'Pending' else 'Failed' end,
         "CreateError" = left(nullif(p_error, ''), 500)
   where "PaymentID" = p_payment_id and "Status" = 'Creating';
$$;

revoke all on function public._xendit_set_invoice(uuid, text, text, timestamptz, text) from public, anon, authenticated;
grant execute on function public._xendit_set_invoice(uuid, text, text, timestamptz, text) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Apply a paid invoice to its order. Never raises: the outcome lands on the row.

create or replace function public._apply_xendit_payment(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  x public."XenditPayments"%rowtype;
  v_order public."OnlineOrders"%rowtype;
  v_has_order boolean := false;
  v_amount numeric;
  v_paid numeric;
  v_method text;
  v_reference text;
begin
  select * into x from public."XenditPayments" where "PaymentID" = p_payment_id for update;
  if not found or x."Status" <> 'Paid' or x."ApplyStatus" = 'Applied' then
    return;
  end if;

  v_amount := coalesce(x."PaidAmount", x."Amount");
  v_method := left(case when x."IsTest" then 'Xendit TEST ' else 'Xendit ' end || coalesce(nullif(x."PaymentChannel", ''), x."PaymentMethod", ''), 30);
  v_reference := left(case when x."IsTest" then '[TEST] ' else '' end || 'Xendit ' || x."Purpose" || ' - ' || coalesce(x."XenditPaymentRef", x."InvoiceID", x."ExternalID"), 200);

  begin
    -- The order may have been confirmed since the invoice was made: re-resolve.
    if x."AutomatedOrderNo" is not null then
      select * into v_order from public."OnlineOrders" o
       where o."OrderID" = coalesce((select nullif(trim(a."PancakeReceiptNo"), '') from public."AutomatedOrders" a
                                      where a."OrderNo" = x."AutomatedOrderNo"), x."AutomatedOrderNo");
      v_has_order := found;
    end if;
    if not v_has_order and x."OnlineOrderID" is not null then
      select * into v_order from public."OnlineOrders" where "OrderID" = x."OnlineOrderID";
      v_has_order := found;
    end if;

    -- AO- draft (not confirmed yet): straight onto its payments (Confirm Order carries them over).
    if not v_has_order then
      if x."AutomatedOrderNo" is null then
        raise exception 'Order % is no longer on the portal.', x."OrderRef";
      end if;
      insert into public."AutomatedOrderPayments" ("OrderNo", "Amount", "Method", "Reference", "RecordedBy")
      values (x."AutomatedOrderNo", v_amount, v_method, v_reference, 'Xendit');
      update public."XenditPayments"
         set "ApplyStatus" = 'Applied', "AppliedAmount" = v_amount, "ApplyError" = null,
             "AppliedIn" = 'Automated order (draft)', "AppliedAtUtc" = now()
       where "PaymentID" = x."PaymentID";
      return;
    end if;

    -- Never written to Pancake. Invoices are refused for non-portal orders, so this only happens if an
    -- order changed after the invoice was made - staff record it by hand.
    if not public._is_portal_only_online_order(v_order."OrderID") then
      raise exception 'Order % is not a portal order - add this % payment on the order by hand, then ignore this row.', v_order."OrderID", v_amount;
    end if;

    -- Portal AO- order: AutomatedOrderPayments + Amount Paid / Balance. The money is already taken,
    -- so the full amount is recorded even if it's more than the balance (staff can see / fix it).
    if not exists (select 1 from public."AutomatedOrders" where "OrderNo" = v_order."OrderID") then
      raise exception 'Order % has no Automated Order record to add the payment to.', v_order."OrderID";
    end if;
    insert into public."AutomatedOrderPayments" ("OrderNo", "Amount", "Method", "Reference", "RecordedBy")
    values (v_order."OrderID", v_amount, v_method, v_reference, 'Xendit');
    v_paid := coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = v_order."OrderID"), 0);
    update public."OnlineOrders" o
       set "AmountPaid" = v_paid,
           "Balance" = coalesce(o."MoneyToCollect", 0) - v_paid,
           "LastPaid_Date" = (now() at time zone 'Asia/Manila')::date,
           "LastPaid_Time" = to_char(now() at time zone 'Asia/Manila', 'HH24:MI:SS')
     where o."OrderID" = v_order."OrderID";
    update public."XenditPayments"
       set "ApplyStatus" = 'Applied', "AppliedAmount" = v_amount, "ApplyError" = null,
           "AppliedIn" = 'Portal (AO order)', "AppliedAtUtc" = now()
     where "PaymentID" = x."PaymentID";
  exception when others then
    update public."XenditPayments"
       set "ApplyStatus" = 'Failed', "AppliedAmount" = 0, "ApplyError" = left(sqlerrm, 500)
     where "PaymentID" = x."PaymentID";
  end;
end;
$$;

revoke all on function public._apply_xendit_payment(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Edge Function only: record an invoice's status from Xendit (webhook, already verified against
--    Xendit's own GET /v2/invoices/{id}). Idempotent - Xendit retries webhooks.

drop function if exists public._xendit_record_invoice_status(jsonb, jsonb);

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
             "PaidAmount" = coalesce(nullif(p_invoice ->> 'paid_amount', '')::numeric, nullif(p_invoice ->> 'amount', '')::numeric, "Amount"),
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
-- 6. Xendit Payments page (super users)

drop function if exists public.admin_list_xendit_payments(text, text, text, int);

create or replace function public.admin_list_xendit_payments(p_admin_username text, p_admin_password text,
                                                            p_search text default null, p_limit int default 200)
returns table(payment_id uuid, created_at timestamptz, order_ref text, online_order_id text, purpose text,
              amount numeric, is_test boolean, status text, invoice_url text, expires_at timestamptz,
              create_error text, paid_amount numeric, payment_method text, payment_channel text, paid_at timestamptz,
              apply_status text, apply_error text, applied_in text, applied_amount numeric, external_id text)
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
           x."PaymentChannel", x."PaidAtUtc", x."ApplyStatus", x."ApplyError", x."AppliedIn", x."AppliedAmount", x."ExternalID"
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

drop function if exists public.admin_retry_xendit_payment(text, text, uuid);

create or replace function public.admin_retry_xendit_payment(p_admin_username text, p_admin_password text, p_payment_id uuid)
returns table(apply_status text, apply_error text)
language plpgsql
security definer
set search_path = public
set statement_timeout = '90000'
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  update public."XenditPayments" set "ApplyStatus" = 'Pending'
   where "PaymentID" = p_payment_id and "Status" = 'Paid' and "ApplyStatus" = 'Failed';
  perform public._apply_xendit_payment(p_payment_id);
  return query select x."ApplyStatus", x."ApplyError" from public."XenditPayments" x where x."PaymentID" = p_payment_id;
end;
$$;

grant execute on function public.admin_retry_xendit_payment(text, text, uuid) to anon;

drop function if exists public.admin_get_xendit_settings(text, text);

create or replace function public.admin_get_xendit_settings(p_admin_username text, p_admin_password text)
returns table(enabled boolean, show_on_order_now boolean, updated_by text, updated_at timestamptz)
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
    select s."Enabled", s."ShowOnOrderNow", s."UpdatedBy", s."UpdatedAtUtc"
      from public."XenditSettings" s where s."Id" = 1;
end;
$$;

grant execute on function public.admin_get_xendit_settings(text, text) to anon;

drop function if exists public.admin_update_xendit_settings(text, text, boolean, text);
drop function if exists public.admin_update_xendit_settings(text, text, boolean, boolean, text);
drop function if exists public.admin_update_xendit_settings(text, text, boolean, boolean);

create or replace function public.admin_update_xendit_settings(p_admin_username text, p_admin_password text,
                                                              p_enabled boolean, p_show_on_order_now boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  update public."XenditSettings"
     set "Enabled" = coalesce(p_enabled, false),
         "ShowOnOrderNow" = coalesce(p_show_on_order_now, false),
         "UpdatedBy" = p_admin_username,
         "UpdatedAtUtc" = now()
   where "Id" = 1;
end;
$$;

grant execute on function public.admin_update_xendit_settings(text, text, boolean, boolean) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'table' as section, c.relname::text as item, 'ok' as value
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relname in ('XenditSettings', 'XenditPayments')
union all
select 'function', p.proname::text,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon'
            when has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role only'
            else 'internal' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and (p.proname like '%xendit%')
union all
select 'settings', 'Enabled / ShowOnOrderNow',
       "Enabled"::text || ' / ' || "ShowOnOrderNow"::text
  from public."XenditSettings" where "Id" = 1;
