-- POS "Online Pay" - per "give me a Online Pay then ask for the order id that they are paying .. once
-- they input the orderid it will lookup the portal's online order id then show the details that they
-- are paying.. once confirmed they can now pay it base on the tender type".
--
-- Goal: the desktop POS stops keeping its own copy of online orders (the order sync makes the local SQL
-- big and slow). Instead it looks up ONE order live from the portal when a customer pays at the store:
--   pos_get_online_order_for_payment  Order ID -> customer, status, items, total, amount paid, balance.
--                                     Re-reads the order from Pancake first, so the balance is current.
--   pos_record_online_order_payment   records the store payment:
--                                       - Pancake order: adds it to Pancake's `cash` / `bank_payments`
--                                         (same fields the old POS PAY wrote), then refreshes the portal copy;
--                                       - portal-only AO- order (no Pancake): AutomatedOrderPayments + the
--                                         portal order's Amount Paid / Balance (same as GMA Add Payment);
--                                       - on the portal but not in Pancake (Pancake says no such order):
--                                         straight onto the portal order's Amount Paid / Balance.
--                                     Logged in OnlineOrderStorePayments ("RecordedIn" says which).
--
-- Rules (agreed in chat): no internet = no payment (the POS needs both calls to succeed); any order can
-- be paid except Cancelled ones; a payment can't be more than the balance.
--
-- Retry-safe: the POS sends its own PaymentID (a GUID). Calling again with the same ID never adds the
-- payment twice - an applied ID just returns its result, and a half-finished one checks Pancake first
-- (already there -> marked applied; untouched -> sent again; changed by someone else -> stops).
--
-- Auth: the POS has no portal login, and the publishable key is public (web pages), so both calls need
-- the POS key (Vault secret POS_API_KEY, also in GlobalSettings.PosApiKey on the desktop).
--
-- Run AFTER supabase_online_order_refresh_payments.sql (_refresh_open_online_order with 2 args),
-- supabase_bot_orders_portal_confirm.sql (_is_portal_only_online_order) and
-- supabase_secure_pancake_credentials.sql (_pancake_api_key). Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. POS key (Vault) + check

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'POS_API_KEY') then
    perform vault.create_secret('pos_6385f793ed5792e50fa8dc35b19a23e51f28ae1c2d4cb149', 'POS_API_KEY',
                                'Desktop POS key for the pos_* RPCs (Online Pay)');
  end if;
end $$;

create or replace function public._pos_key_ok(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public, vault
as $$
  select coalesce(
    nullif(trim(coalesce(p_key, '')), '') = (select decrypted_secret from vault.decrypted_secrets where name = 'POS_API_KEY' limit 1),
    false);
$$;

revoke all on function public._pos_key_ok(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Store payment log

create table if not exists public."OnlineOrderStorePayments" (
  "PaymentID" uuid primary key,              -- made by the POS; same ID on a retry
  "OrderID" text not null,
  "Tenders" jsonb not null,                  -- [{tender_code, tender_name, bank_key, amount}]
  "Amount" numeric(18, 2) not null,
  "Cashier" text,
  "Terminal" text,
  "ReceiptNo" text,
  "Status" text not null default 'Pending',  -- Pending / Applied / Failed
  "Error" text,
  "AmountPaidBefore" numeric(18, 2),
  "BalanceBefore" numeric(18, 2),
  "AmountPaidAfter" numeric(18, 2),
  "BalanceAfter" numeric(18, 2),
  "PancakeBefore" jsonb,                     -- cash / changed bank keys before the payment
  "PancakeTarget" jsonb,                     -- the same after it (absolute amounts)
  "CreatedAtUtc" timestamptz not null default now(),
  "AppliedAtUtc" timestamptz
);

-- Where the payment went: 'Pancake', 'Portal (AO order)' or 'Portal (not in Pancake)'.
alter table public."OnlineOrderStorePayments" add column if not exists "RecordedIn" text;

create index if not exists "IX_OnlineOrderStorePayments_OrderID" on public."OnlineOrderStorePayments" ("OrderID");

alter table public."OnlineOrderStorePayments" enable row level security;
revoke all on public."OnlineOrderStorePayments" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Pancake helpers

-- One order from Pancake (3 tries). Raises when Pancake can't be reached / errors. Returns NULL when
-- Pancake answers that it has no such order (404, success=false, or a reply with no order in it) - a
-- portal-only order. (Without this, the blank amounts parsed as 0 - pancake_parse_decimal - and the
-- payment was refused as "more than the balance in Pancake (0.00)".)
create or replace function public._pos_pay_pancake_get(p_order_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id || '?api_key=' || public._pancake_api_key();
  v_resp extensions.http_response;
  v_body jsonb;
  v_attempt int := 0;
  v_last_error text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
  loop
    v_attempt := v_attempt + 1;
    begin
      select * into v_resp from extensions.http_get(v_url);
      exit when v_resp.status < 500;
      v_last_error := format('HTTP %s', v_resp.status);
    exception when others then
      v_last_error := sqlerrm;
    end;
    if v_attempt >= 3 then
      raise exception 'Could not reach Pancake after 3 tries (%).', v_last_error;
    end if;
    perform pg_sleep(v_attempt);
  end loop;

  if v_resp.status = 404 then
    return null;
  end if;
  if v_resp.status < 200 or v_resp.status >= 300 then
    raise exception 'Could not read order % from Pancake (HTTP %).', p_order_id, v_resp.status;
  end if;

  begin
    v_body := v_resp.content::jsonb;
  exception when others then
    raise exception 'Pancake sent an unreadable reply for order %.', p_order_id;
  end;
  if jsonb_typeof(v_body) <> 'object' or lower(coalesce(v_body ->> 'success', '')) = 'false' then
    return null;
  end if;
  v_body := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body -> 'order') = 'object' then v_body -> 'order'
    else v_body
  end;
  -- A real order always has its id and status.
  if not (v_body ? 'id' or v_body ? 'status') then
    return null;
  end if;
  return v_body;
end;
$$;

-- The payment fields of a Pancake order: {cash, bank: {key: amount}, money, prepaid}. Same parsing as
-- admin_get_online_order_payment_methods (cash / bank_payments) and _refresh_open_online_order (money / prepaid).
create or replace function public._pos_pay_pancake_state(p_el jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_bank jsonb := '{}'::jsonb;
  v_key text;
  v_value jsonb;
  v_amount numeric;
  v_cash numeric;
begin
  begin
    v_cash := nullif(trim(coalesce(p_el ->> 'cash', '')), '')::numeric;
  exception when others then
    v_cash := null;
  end;

  if jsonb_typeof(p_el -> 'bank_payments') = 'object' then
    for v_key, v_value in select * from jsonb_each(p_el -> 'bank_payments') loop
      begin
        v_amount := case
          when jsonb_typeof(v_value) = 'object' then coalesce(v_value ->> 'amount', v_value ->> 'value')::numeric
          else nullif(trim(v_value #>> '{}'), '')::numeric
        end;
      exception when others then
        v_amount := null;
      end;
      if v_amount is not null then
        v_bank := v_bank || jsonb_build_object(v_key, v_amount);
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'cash', coalesce(v_cash, 0),
    'bank', v_bank,
    'money', public.pancake_parse_decimal(coalesce(
      p_el -> 'money_to_collect' ->> 'amount', p_el -> 'money_to_collect' ->> 'value', p_el -> 'money_to_collect' ->> 'total',
      p_el ->> 'money_to_collect', p_el ->> 'moneyToCollect', p_el ->> 'total_price', p_el ->> 'total', p_el ->> 'amount', p_el ->> 'money')),
    'prepaid', public.pancake_parse_decimal(coalesce(
      p_el -> 'prepaid' ->> 'amount', p_el -> 'prepaid' ->> 'value',
      p_el ->> 'prepaid', p_el ->> 'prepaid_amount', p_el ->> 'pre_paid', p_el ->> 'deposit', p_el ->> 'prepayment')));
end;
$$;

-- Does Pancake's current state have the amounts in p_target ({cash: n or null, bank: {key: n}})?
-- A null cash means "cash not part of this payment" and isn't compared.
create or replace function public._pos_pay_state_matches(p_state jsonb, p_target jsonb)
returns boolean
language sql
immutable
as $$
  select (p_target ->> 'cash' is null
          or round(coalesce((p_state ->> 'cash')::numeric, 0), 2) = round((p_target ->> 'cash')::numeric, 2))
     and not exists (
       select 1 from jsonb_each_text(coalesce(p_target -> 'bank', '{}'::jsonb)) t
       where round(coalesce((p_state -> 'bank' ->> t.key)::numeric, 0), 2) <> round(t.value::numeric, 2));
$$;

revoke all on function public._pos_pay_pancake_get(text) from public, anon, authenticated;
revoke all on function public._pos_pay_pancake_state(jsonb) from public, anon, authenticated;
revoke all on function public._pos_pay_state_matches(jsonb, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Lookup: one order, fresh from Pancake

create or replace function public.pos_get_online_order_for_payment(p_pos_key text, p_order_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_id text := trim(coalesce(p_order_id, ''));
  v_portal boolean;
  v_fresh boolean := false;
  v_o public."OnlineOrders"%rowtype;
  v_warehouse text;
  v_lines jsonb;
  v_block text;
  v_unfinished text;
begin
  if not public._pos_key_ok(p_pos_key) then
    raise exception 'Not authorized.';
  end if;
  if v_id = '' then
    raise exception 'Enter an Order ID.';
  end if;

  if not exists (select 1 from public."OnlineOrders" where "OrderID" = v_id) then
    return jsonb_build_object('found', false, 'order_id', v_id);
  end if;

  v_portal := public._is_portal_only_online_order(v_id);
  if not v_portal then
    -- On the portal but not in Pancake: same as an AO order - the portal row is the only copy.
    begin
      v_portal := public._pos_pay_pancake_get(v_id) is null;
    exception when others then
      null; -- Pancake unreachable - the refresh below just won't stamp it fresh
    end;
  end if;
  if v_portal then
    v_fresh := true; -- no Pancake order - the portal row is the only copy
  else
    -- Same refresh the open-order rotation runs (payments, status, lines when missing). It stamps
    -- SyncedAtUtc = now() only when Pancake answered, which is how "fresh" is told apart.
    begin
      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');
      perform public._refresh_open_online_order(v_id);
    exception when others then
      null;
    end;
    select coalesce("SyncedAtUtc" >= now(), false) into v_fresh from public."OnlineOrders" where "OrderID" = v_id;
  end if;

  select * into v_o from public."OnlineOrders" where "OrderID" = v_id;
  select w."Name" into v_warehouse from public."Warehouses" w where w."ID" = v_o."LocationID";

  select coalesce(jsonb_agg(jsonb_build_object(
           'description', coalesce(nullif(trim(l."Description"), ''), l."ItemCode", ''),
           'item_code', l."ItemCode",
           'qty', coalesce(l."Quantity", 0),
           'price', coalesce(l."Price", 0),
           'amount', round(coalesce(l."Quantity", 0) * coalesce(l."Price", 0), 2))
         order by length(l."LineID"), l."LineID"), '[]'::jsonb)
    into v_lines
  from public."OnlineOrderLines" l
  where l."OrderID" = v_id;

  v_block := case
    when lower(trim(coalesce(v_o."Status", ''))) in ('canceled', 'cancelled', 'cancel') then 'This order is Cancelled - it can''t be paid.'
    when coalesce(v_o."Balance", 0) <= 0 then 'Nothing to pay - this order is fully paid.'
    else null
  end;

  -- An earlier POS payment for this order that never finished (e.g. the internet dropped mid-payment).
  select format('An earlier store payment of %s (%s, %s) did not finish: %s. Check the order on the portal before taking payment again.',
                to_char(p."Amount", 'FM999,999,990.00'), coalesce(p."Cashier", '?'),
                to_char(p."CreatedAtUtc" at time zone 'Asia/Manila', 'Mon DD HH24:MI'), coalesce(p."Error", p."Status"))
    into v_unfinished
  from public."OnlineOrderStorePayments" p
  where p."OrderID" = v_id and p."Status" <> 'Applied' and p."CreatedAtUtc" > now() - interval '3 days'
  order by p."CreatedAtUtc" desc
  limit 1;

  return jsonb_build_object(
    'found', true,
    'order_id', v_o."OrderID",
    'customer_name', v_o."CustomerName",
    'phone', v_o."ShippingPhone",
    'status', v_o."Status",
    'warehouse', v_warehouse,
    'order_date', v_o."Date",
    'total', coalesce(v_o."MoneyToCollect", 0),
    'discount', coalesce(v_o."Discount", 0),
    'delivery_fee', coalesce(v_o."DeliveryFee", 0),
    'amount_paid', coalesce(v_o."AmountPaid", 0),
    'balance', coalesce(v_o."Balance", 0),
    'portal_only', v_portal,
    'fresh', v_fresh,
    'lines', v_lines,
    'can_pay', v_block is null,
    'block_reason', v_block,
    'unfinished_payment', v_unfinished);
end;
$$;

grant execute on function public.pos_get_online_order_for_payment(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 5. Record a store payment

create or replace function public.pos_record_online_order_payment(
  p_pos_key text,
  p_payment_id uuid,
  p_order_id text,
  p_tenders jsonb,                 -- [{tender_code, tender_name, bank_key, amount}]
  p_cashier text default null,
  p_terminal text default null,
  p_receipt_no text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '90000'
as $$
declare
  v_id text := trim(coalesce(p_order_id, ''));
  v_row public."OnlineOrderStorePayments"%rowtype;
  v_has_row boolean;
  v_order public."OnlineOrders"%rowtype;
  v_tenders jsonb;
  v_t jsonb;
  v_amt numeric;
  v_total numeric := 0;
  v_cash_add numeric := 0;
  v_bank_add jsonb := '{}'::jsonb;
  v_bank_key text;
  v_missing_bank text;
  v_portal boolean;
  v_paid_before numeric;
  v_balance_before numeric;
  v_paid_after numeric;
  v_balance_after numeric;
  v_el jsonb;
  v_state jsonb;
  v_before jsonb;
  v_target jsonb;
  v_put jsonb;
  v_skip_put boolean := false;
  v_url text;
  v_resp extensions.http_response;
  v_attempt int;
  v_last_error text;
  v_error text;
  v_portal_updated boolean := false;
begin
  if not public._pos_key_ok(p_pos_key) then
    raise exception 'Not authorized.';
  end if;
  if p_payment_id is null then
    raise exception 'Payment ID is required.';
  end if;
  if v_id = '' then
    raise exception 'Order ID is required.';
  end if;

  -- One store payment per order at a time (two tills paying the same order).
  perform pg_advisory_xact_lock(hashtext('pos-online-pay:' || v_id));

  select * into v_row from public."OnlineOrderStorePayments" where "PaymentID" = p_payment_id;
  v_has_row := found;
  if v_has_row then
    if v_row."OrderID" <> v_id then
      raise exception 'This payment ID belongs to order %.', v_row."OrderID";
    end if;
    if v_row."Status" = 'Applied' then
      return jsonb_build_object('ok', true, 'already_applied', true, 'amount', v_row."Amount",
        'amount_paid_before', v_row."AmountPaidBefore", 'balance_before', v_row."BalanceBefore",
        'amount_paid_after', v_row."AmountPaidAfter", 'balance_after', v_row."BalanceAfter", 'portal_updated', true);
    end if;
  end if;

  -- A retry uses the tenders saved on the first try, never new ones.
  v_tenders := case when v_has_row then v_row."Tenders" else p_tenders end;
  if jsonb_typeof(v_tenders) is distinct from 'array' or jsonb_array_length(v_tenders) = 0 then
    raise exception 'No tenders given.';
  end if;

  for v_t in select * from jsonb_array_elements(v_tenders) loop
    v_amt := round(coalesce(nullif(trim(coalesce(v_t ->> 'amount', '')), '')::numeric, 0), 2);
    if v_amt <= 0 then
      raise exception 'Each tender needs an amount above zero.';
    end if;
    v_total := v_total + v_amt;
    v_bank_key := nullif(trim(coalesce(v_t ->> 'bank_key', '')), '');
    if upper(trim(coalesce(v_t ->> 'tender_code', ''))) = 'CASH' then
      v_cash_add := v_cash_add + v_amt;
    elsif v_bank_key is not null then
      v_bank_add := v_bank_add || jsonb_build_object(v_bank_key, coalesce((v_bank_add ->> v_bank_key)::numeric, 0) + v_amt);
    else
      v_missing_bank := coalesce(nullif(trim(coalesce(v_t ->> 'tender_name', '')), ''), v_t ->> 'tender_code');
    end if;
  end loop;

  select * into v_order from public."OnlineOrders" where "OrderID" = v_id;
  if not found then
    raise exception 'Order % is not on the portal.', v_id;
  end if;
  if lower(trim(coalesce(v_order."Status", ''))) in ('canceled', 'cancelled', 'cancel') then
    raise exception 'Order % is Cancelled - it can''t be paid.', v_id;
  end if;

  v_portal := public._is_portal_only_online_order(v_id);

  -- ---- Portal-only (AO-) order: no Pancake - same as GMA Conversations' Add Payment.
  if v_portal then
    if not exists (select 1 from public."AutomatedOrders" where "OrderNo" = v_id) then
      raise exception 'Order % has no Automated Order record to add the payment to.', v_id;
    end if;
    v_paid_before := coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = v_id), 0);
    v_balance_before := coalesce(v_order."MoneyToCollect", 0) - v_paid_before;
    if v_total > v_balance_before + 0.005 then
      raise exception 'The payment (%) is more than the balance (%).', v_total, round(v_balance_before, 2);
    end if;

    for v_t in select * from jsonb_array_elements(v_tenders) loop
      insert into public."AutomatedOrderPayments" ("OrderNo", "Amount", "Method", "Reference", "RecordedBy")
      values (v_id,
              round((v_t ->> 'amount')::numeric, 2),
              left(coalesce(nullif(trim(coalesce(v_t ->> 'tender_name', '')), ''), nullif(trim(coalesce(v_t ->> 'tender_code', '')), ''), 'Cash'), 30),
              left('POS ' || coalesce(nullif(trim(p_receipt_no), ''), 'store payment'), 200),
              left('POS:' || coalesce(nullif(trim(p_cashier), ''), '?'), 100));
    end loop;

    v_paid_after := v_paid_before + v_total;
    v_balance_after := v_balance_before - v_total;

    update public."OnlineOrders" o
    set "AmountPaid" = v_paid_after,
        "Balance" = coalesce(o."MoneyToCollect", 0) - v_paid_after,
        "LastPaid_Date" = (now() at time zone 'Asia/Manila')::date,
        "LastPaid_Time" = to_char(now() at time zone 'Asia/Manila', 'HH24:MI:SS')
    where o."OrderID" = v_id;

    insert into public."OnlineOrderStorePayments" ("PaymentID", "OrderID", "Tenders", "Amount", "Cashier", "Terminal", "ReceiptNo",
      "Status", "RecordedIn", "AmountPaidBefore", "BalanceBefore", "AmountPaidAfter", "BalanceAfter", "AppliedAtUtc")
    values (p_payment_id, v_id, v_tenders, v_total, p_cashier, p_terminal, p_receipt_no,
      'Applied', 'Portal (AO order)', v_paid_before, v_balance_before, v_paid_after, v_balance_after, now())
    on conflict ("PaymentID") do update set
      "Status" = 'Applied', "Error" = null, "AmountPaidBefore" = excluded."AmountPaidBefore", "BalanceBefore" = excluded."BalanceBefore",
      "AmountPaidAfter" = excluded."AmountPaidAfter", "BalanceAfter" = excluded."BalanceAfter", "AppliedAtUtc" = now();

    return jsonb_build_object('ok', true, 'already_applied', false, 'amount', v_total,
      'amount_paid_before', v_paid_before, 'balance_before', v_balance_before,
      'amount_paid_after', v_paid_after, 'balance_after', v_balance_after, 'portal_updated', true);
  end if;

  -- Raises (nothing saved yet - safe to try again) when Pancake can't be reached; NULL = Pancake has no
  -- such order.
  v_el := public._pos_pay_pancake_get(v_id);

  -- ---- On the portal but not in Pancake - per "i think the order that is getting paid is not on pancake
  -- but on portal.. if thats the case can we allow the payment and update the payment". The portal row
  -- is the only copy (no Pancake sync will overwrite it), so the payment goes straight onto its Amount
  -- Paid / Balance. One transaction, no outside call - a retry finds it Applied.
  if v_el is null then
    if v_has_row then
      update public."OnlineOrderStorePayments"
      set "Status" = 'Failed', "Error" = 'Pancake no longer has this order since the first try.'
      where "PaymentID" = p_payment_id;
      return jsonb_build_object('ok', false, 'error',
        'Pancake no longer has this order since this payment was first tried, so it was NOT recorded. Check the order on the portal.');
    end if;

    v_paid_before := coalesce(v_order."AmountPaid", 0);
    v_balance_before := coalesce(v_order."MoneyToCollect", 0) - v_paid_before;
    if v_total > v_balance_before + 0.005 then
      raise exception 'The payment (%) is more than the balance (%).', v_total, round(v_balance_before, 2);
    end if;
    v_paid_after := v_paid_before + v_total;
    v_balance_after := v_balance_before - v_total;

    update public."OnlineOrders" o
    set "AmountPaid" = v_paid_after,
        "Balance" = coalesce(o."MoneyToCollect", 0) - v_paid_after,
        "LastPaid_Date" = (now() at time zone 'Asia/Manila')::date,
        "LastPaid_Time" = to_char(now() at time zone 'Asia/Manila', 'HH24:MI:SS')
    where o."OrderID" = v_id;

    insert into public."OnlineOrderStorePayments" ("PaymentID", "OrderID", "Tenders", "Amount", "Cashier", "Terminal", "ReceiptNo",
      "Status", "RecordedIn", "AmountPaidBefore", "BalanceBefore", "AmountPaidAfter", "BalanceAfter", "AppliedAtUtc")
    values (p_payment_id, v_id, v_tenders, v_total, p_cashier, p_terminal, p_receipt_no,
      'Applied', 'Portal (not in Pancake)', v_paid_before, v_balance_before, v_paid_after, v_balance_after, now());

    return jsonb_build_object('ok', true, 'already_applied', false, 'amount', v_total,
      'amount_paid_before', v_paid_before, 'balance_before', v_balance_before,
      'amount_paid_after', v_paid_after, 'balance_after', v_balance_after, 'portal_updated', true);
  end if;

  -- ---- Pancake order.
  if v_missing_bank is not null then
    raise exception 'Tender "%" has no POS Bank ID in Tender Types, so Pancake can''t record it. Set its POS Bank ID first, or use another tender.', v_missing_bank;
  end if;

  v_state := public._pos_pay_pancake_state(v_el);

  if v_has_row then
    -- Retry of an earlier try that didn't finish.
    v_before := v_row."PancakeBefore";
    v_target := v_row."PancakeTarget";
    v_paid_before := v_row."AmountPaidBefore";
    v_balance_before := v_row."BalanceBefore";
    if public._pos_pay_state_matches(v_state, v_target) then
      v_skip_put := true; -- the earlier try reached Pancake; only its reply was lost
    elsif not public._pos_pay_state_matches(v_state, v_before) then
      update public."OnlineOrderStorePayments"
      set "Status" = 'Failed', "Error" = 'Pancake payments changed since the first try - check the order before paying again.'
      where "PaymentID" = p_payment_id;
      return jsonb_build_object('ok', false, 'error',
        'The order''s payments in Pancake changed since this payment was first tried, so it was NOT sent again. Check the order on the portal before taking payment.');
    end if;
  else
    v_paid_before := coalesce((v_state ->> 'prepaid')::numeric, v_order."AmountPaid", 0);
    v_balance_before := coalesce((v_state ->> 'money')::numeric, v_order."MoneyToCollect", 0) - v_paid_before;
    if v_total > v_balance_before + 0.005 then
      raise exception 'The payment (%) is more than the balance in Pancake (%).', v_total, round(v_balance_before, 2);
    end if;

    v_before := jsonb_build_object(
      'cash', case when v_cash_add > 0 then (v_state ->> 'cash')::numeric end,
      'bank', (select coalesce(jsonb_object_agg(k, coalesce((v_state -> 'bank' ->> k)::numeric, 0)), '{}'::jsonb)
               from jsonb_object_keys(v_bank_add) k));
    v_target := jsonb_build_object(
      'cash', case when v_cash_add > 0 then (v_state ->> 'cash')::numeric + v_cash_add end,
      'bank', (select coalesce(jsonb_object_agg(k, coalesce((v_state -> 'bank' ->> k)::numeric, 0) + (v_bank_add ->> k)::numeric), '{}'::jsonb)
               from jsonb_object_keys(v_bank_add) k));

    insert into public."OnlineOrderStorePayments" ("PaymentID", "OrderID", "Tenders", "Amount", "Cashier", "Terminal", "ReceiptNo",
      "Status", "RecordedIn", "AmountPaidBefore", "BalanceBefore", "PancakeBefore", "PancakeTarget")
    values (p_payment_id, v_id, v_tenders, v_total, p_cashier, p_terminal, p_receipt_no,
      'Pending', 'Pancake', v_paid_before, v_balance_before, v_before, v_target);
  end if;

  -- From here nothing raises: the Pending row must be kept so a retry can tell whether Pancake got it.
  if not v_skip_put then
    -- Full bank_payments + cash every time (an update without them can wipe them), with absolute
    -- amounts, so a retried PUT writes the same totals instead of adding again. Same PUT the old POS PAY used.
    v_put := jsonb_build_object(
      'bank_payments', coalesce(v_state -> 'bank', '{}'::jsonb) || coalesce(v_target -> 'bank', '{}'::jsonb),
      'cash', coalesce((v_target ->> 'cash')::numeric, (v_state ->> 'cash')::numeric, 0));
    v_url := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || v_id || '?api_key=' || public._pancake_api_key();
    begin
      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
      v_attempt := 0;
      loop
        v_attempt := v_attempt + 1;
        begin
          select * into v_resp from extensions.http((
            'PUT', v_url,
            array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
            'application/json',
            v_put::text
          )::extensions.http_request);
          exit when v_resp.status < 500;
          v_last_error := format('HTTP %s', v_resp.status);
        exception when others then
          v_last_error := sqlerrm;
        end;
        if v_attempt >= 3 then
          raise exception 'Could not reach Pancake after 3 tries (%).', v_last_error;
        end if;
        perform pg_sleep(v_attempt);
      end loop;
      if v_resp.status < 200 or v_resp.status >= 300 then
        raise exception 'Pancake rejected the payment (HTTP %): %', v_resp.status, left(v_resp.content, 300);
      end if;
    exception when others then
      v_error := sqlerrm;
    end;
  end if;

  if v_error is not null then
    update public."OnlineOrderStorePayments" set "Status" = 'Failed', "Error" = v_error where "PaymentID" = p_payment_id;
    return jsonb_build_object('ok', false, 'error', v_error);
  end if;

  v_paid_after := v_paid_before + (select "Amount" from public."OnlineOrderStorePayments" where "PaymentID" = p_payment_id);
  v_balance_after := v_balance_before - (select "Amount" from public."OnlineOrderStorePayments" where "PaymentID" = p_payment_id);

  update public."OnlineOrderStorePayments"
  set "Status" = 'Applied', "Error" = null, "AmountPaidAfter" = v_paid_after, "BalanceAfter" = v_balance_after, "AppliedAtUtc" = now()
  where "PaymentID" = p_payment_id;

  -- Portal copy: re-read from Pancake (Amount Paid comes from Pancake's prepaid). If Pancake couldn't be
  -- read, write the computed amounts so the portal shows the payment now; the rotation corrects it later.
  begin
    perform public._refresh_open_online_order(v_id);
    select coalesce("SyncedAtUtc" >= now() and "AmountPaid" >= v_paid_after - 0.01, false) into v_portal_updated
    from public."OnlineOrders" where "OrderID" = v_id;
  exception when others then
    v_portal_updated := false;
  end;

  update public."OnlineOrders" o
  set "AmountPaid" = case when v_portal_updated then o."AmountPaid" else v_paid_after end,
      "Balance" = case when v_portal_updated then o."Balance" else coalesce(o."MoneyToCollect", 0) - v_paid_after end,
      "LastPaid_Date" = (now() at time zone 'Asia/Manila')::date,
      "LastPaid_Time" = to_char(now() at time zone 'Asia/Manila', 'HH24:MI:SS')
  where o."OrderID" = v_id;

  return jsonb_build_object('ok', true, 'already_applied', v_skip_put, 'amount', v_paid_after - v_paid_before,
    'amount_paid_before', v_paid_before, 'balance_before', v_balance_before,
    'amount_paid_after', v_paid_after, 'balance_after', v_balance_after, 'portal_updated', v_portal_updated);
end;
$$;

grant execute on function public.pos_record_online_order_payment(text, uuid, text, jsonb, text, text, text) to anon;

notify pgrst, 'reload schema';
