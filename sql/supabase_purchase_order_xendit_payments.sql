-- Pay a Purchase Order's supplier through Xendit - per "can we make a payment in the PO to the supplier?" ...
-- "what I mean is to pay it via xendit" ... "yes correct same flow and full PO total or downpayment is allowed".
--
-- Same flow as Xendit cash advances (supabase_xendit_cash_advance_payouts.sql):
--   1. Vendors > Manage > Xendit Payout Account (super users): where the supplier is paid (GCash / Maya / bank,
--      account number, account name). Every change sends a Telegram alert - whoever can edit it decides where
--      money goes.
--   2. Purchase Order card > Xendit Payments > Request Payment (any staff): the full balance or a down payment.
--      Saved as a request, Telegram tells the super users. Total requested can't go over the PO total.
--   3. A super user presses Approve & Send: the xendit-vendor-payout Edge Function sends it (same XenditPayouts
--      table, payout key, v2/v3 routing, Idempotency-key and webhook as salary payouts; Kind 'Vendor',
--      reference RSPS-PAY-PO-...). The supplier gets Xendit's emailed proof at the vendor's Email (records CC
--      from XENDIT_PAYOUT_RECEIPT_CC).
--   4. Posting the PO: the bill is paid first from the Xendit payouts that SUCCEEDED (method 'Xendit', credited to
--      the Digital / Bank account), the rest by the PO's Payment Method (Cash / Online). Payment Method 'Xendit' =
--      fully paid through Xendit, so posting refuses if Xendit hasn't covered the bill. A Xendit payment above
--      what was received stays on the vendor as a credit (an unapplied vendor payment).
--      Posting is refused while a request is still awaiting approval, sending, or failed (cancel it first).
--   5. A PO with Xendit money out (sending or paid) can't be deleted or merged away.
-- Test-mode payouts never count as paid (no real money).
--
-- Run AFTER supabase_purchase_order_paid_on_post.sql (replaces _create_vendor_payment and
-- staff_post_purchase_order), supabase_purchase_order_payment_method.sql (replaces
-- staff_set_purchase_order_payment_method) and the Xendit payout files (supabase_xendit_owner_payouts.sql
-- replaced CK_XenditPayouts_Kind last - this one replaces it again, keeping Owner). Safe to re-run.
-- Needs the xendit-vendor-payout Edge Function, js/purchaseOrders.js ?v=poxendit1 and js/vendorSetup.js
-- ?v=vendorpayout1. Ends with ONE result.

-- ---------------------------------------------------------------------------
-- 1. Vendor payout account.

alter table public."Vendors" add column if not exists "PayoutChannelCode" text;
alter table public."Vendors" add column if not exists "PayoutChannelName" text;
alter table public."Vendors" add column if not exists "PayoutAccountNumber" text;
alter table public."Vendors" add column if not exists "PayoutAccountName" text;
alter table public."Vendors" add column if not exists "PayoutUpdatedBy" text;
alter table public."Vendors" add column if not exists "PayoutUpdatedAtUtc" timestamptz;

create or replace function public.admin_get_vendor_payout_account(p_admin_username text, p_admin_password text, p_vendor_code text)
returns table(channel_code text, channel_name text, account_number text, account_name text, updated_by text, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select v."PayoutChannelCode"::text, v."PayoutChannelName"::text, v."PayoutAccountNumber"::text, v."PayoutAccountName"::text,
           v."PayoutUpdatedBy"::text, v."PayoutUpdatedAtUtc"::timestamptz
    from public."Vendors" v where v."VendorCode" = p_vendor_code;
end;
$$;

grant execute on function public.admin_get_vendor_payout_account(text, text, text) to anon;

-- All blank = remove the account. Same checks as the salary payout account (admin_set_payroll_payout_account).
create or replace function public.admin_set_vendor_payout_account(
  p_admin_username text,
  p_admin_password text,
  p_vendor_code text,
  p_channel_code text,
  p_channel_name text,
  p_account_number text,
  p_account_name text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(nullif(trim(coalesce(p_channel_code, '')), ''));
  v_number text := nullif(regexp_replace(coalesce(p_account_number, ''), '[\s-]', '', 'g'), '');
  v_name text := nullif(left(regexp_replace(trim(coalesce(p_account_name, '')), '\s+', ' ', 'g'), 100), '');
  v_channel_name text;
  v_old record;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Only a super user can change a vendor''s payout account.'::text;
    return;
  end if;

  select v."Name", v."PayoutChannelCode", v."PayoutChannelName", v."PayoutAccountNumber", v."PayoutAccountName"
    into v_old
    from public."Vendors" v where v."VendorCode" = p_vendor_code
    for update;
  if not found then
    return query select false, 'Vendor not found.'::text;
    return;
  end if;

  if v_code is not null or v_number is not null or v_name is not null then
    if v_code is null or v_number is null or v_name is null then
      return query select false, 'Pick where to pay, and enter the account number and the account name.'::text;
      return;
    end if;
    if v_code !~ '^[A-Z0-9_]{3,40}$' then
      return query select false, 'Unknown payout channel.'::text;
      return;
    end if;
    if v_code in ('PH_GCASH', 'PH_PAYMAYA', 'PH_GRABPAY', 'PH_SHOPEEPAY') then
      v_number := regexp_replace(v_number, '^(\+?63)', '0');
      if v_number !~ '^09[0-9]{9}$' then
        return query select false, 'Enter the 11-digit mobile number of the wallet, e.g. 09171234567.'::text;
        return;
      end if;
    elsif v_number !~ '^[0-9]{6,20}$' then
      return query select false, 'A bank account number is 6 to 20 digits.'::text;
      return;
    end if;
  end if;

  v_channel_name := case when v_code is null then null else coalesce(nullif(left(trim(coalesce(p_channel_name, '')), 120), ''), v_code) end;

  if v_old."PayoutChannelCode" is not distinct from v_code
     and v_old."PayoutAccountNumber" is not distinct from v_number
     and v_old."PayoutAccountName" is not distinct from v_name then
    return query select true, 'No change.'::text;
    return;
  end if;

  update public."Vendors"
     set "PayoutChannelCode" = v_code,
         "PayoutChannelName" = v_channel_name,
         "PayoutAccountNumber" = v_number,
         "PayoutAccountName" = v_name,
         "PayoutUpdatedBy" = p_admin_username,
         "PayoutUpdatedAtUtc" = now()
   where "VendorCode" = p_vendor_code;

  perform public._telegram_send_message(
    'Vendors: ' || p_admin_username || ' changed the Xendit payout account of ' || coalesce(v_old."Name", p_vendor_code) || E'.\n'
    || 'Was: ' || case when v_old."PayoutChannelCode" is null then 'none'
                       else coalesce(v_old."PayoutChannelName", v_old."PayoutChannelCode") || ' ••' || right(coalesce(v_old."PayoutAccountNumber", ''), 4)
                            || ' (' || coalesce(v_old."PayoutAccountName", '') || ')' end || E'\n'
    || 'Now: ' || case when v_code is null then 'none'
                       else v_channel_name || ' ••' || right(v_number, 4) || ' (' || v_name || ')' end || E'\n'
    || 'Purchase Order payments to this vendor go to this account.');

  return query select true, case when v_code is null then 'Payout account removed.' else 'Payout account saved.' end::text;
end;
$$;

grant execute on function public.admin_set_vendor_payout_account(text, text, text, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Payment Method: + Xendit (= fully paid through Xendit).

alter table public."PurchaseOrders" drop constraint if exists "CK_PurchaseOrders_PaymentMethod";
alter table public."PurchaseOrders"
  add constraint "CK_PurchaseOrders_PaymentMethod" check ("PaymentMethod" is null or "PaymentMethod" in ('Cash', 'Online', 'Xendit'));

alter table public."PostedPurchaseOrders" drop constraint if exists "CK_PostedPurchaseOrders_PaymentMethod";
alter table public."PostedPurchaseOrders"
  add constraint "CK_PostedPurchaseOrders_PaymentMethod" check ("PaymentMethod" is null or "PaymentMethod" in ('Cash', 'Online', 'Xendit'));

create or replace function public.staff_set_purchase_order_payment_method(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_payment_method text default null -- keep the live default (create or replace can't drop it)
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_payment_method text := nullif(trim(coalesce(p_payment_method, '')), '');
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_payment_method is not null and v_payment_method not in ('Cash', 'Online', 'Xendit') then
    raise exception 'Payment Method must be Cash, Online or Xendit.';
  end if;

  if not exists (select 1 from public."PurchaseOrders" where "PONo" = p_po_no) then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  update public."PurchaseOrders" set "PaymentMethod" = v_payment_method where "PONo" = p_po_no;
end;
$$;

grant execute on function public.staff_set_purchase_order_payment_method(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 3. Payment requests, and the payouts that pay them.

create table if not exists public."PurchaseOrderXenditRequests" (
  "RequestID" uuid primary key default gen_random_uuid(),
  "PONo" text not null,                       -- no FK: the PO row is deleted when it posts
  "VendorCode" text not null,
  "Amount" numeric(18, 2) not null check ("Amount" > 0),
  "IsDownPayment" boolean not null default false,
  "Note" text,
  "Status" text not null default 'Submitted' check ("Status" in ('Submitted', 'Cancelled')),
  "RequestedBy" text not null,
  "RequestedAtUtc" timestamptz not null default now(),
  "CancelledBy" text,
  "CancelledAtUtc" timestamptz
);

create index if not exists "IX_POXenditRequests_PONo" on public."PurchaseOrderXenditRequests" ("PONo");

alter table public."PurchaseOrderXenditRequests" enable row level security;
revoke all on public."PurchaseOrderXenditRequests" from anon, authenticated;

alter table public."XenditPayouts" add column if not exists "PONo" text;
alter table public."XenditPayouts" add column if not exists "VendorCode" text;
alter table public."XenditPayouts" add column if not exists "VendorRequestID" uuid
  references public."PurchaseOrderXenditRequests" ("RequestID") on delete set null;

alter table public."XenditPayouts" drop constraint if exists "CK_XenditPayouts_Kind";
alter table public."XenditPayouts"
  add constraint "CK_XenditPayouts_Kind" check (
    ("Kind" = 'Salary' and "RunID" is not null and "LineID" is not null)
    or "Kind" = 'Advance'
    or ("Kind" = 'Owner' and "OwnerAccountKey" is not null)
    or ("Kind" = 'Vendor' and "PONo" is not null and "VendorCode" is not null));

-- One live payout per request still going or done (and one test). A failed one doesn't count - send again.
create unique index if not exists "UX_XenditPayouts_ActiveVendorRequest" on public."XenditPayouts" ("VendorRequestID", "IsTest")
  where "VendorRequestID" is not null and "Status" not in ('FAILED', 'CANCELLED', 'REVERSED', 'Error');
create index if not exists "IX_XenditPayouts_PONo" on public."XenditPayouts" ("PONo") where "PONo" is not null;

-- What the PO's lines add up to (same formula as staff_list_purchase_order_lines' Line Cost).
create or replace function public._po_ordered_total(p_po_no text)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(sum(round(coalesce(l."UnitCost", 0) * coalesce(l."Quantity", 0), 2)), 0)
  from public."PurchaseOrderLines" l where l."PONo" = p_po_no;
$$;

revoke all on function public._po_ordered_total(text) from public, anon, authenticated;

-- Real money paid to the supplier through Xendit for this PO.
create or replace function public._po_xendit_paid_total(p_po_no text)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(sum(x."Amount"), 0) from public."XenditPayouts" x
  where x."Kind" = 'Vendor' and x."PONo" = p_po_no and not x."IsTest" and x."Status" = 'SUCCEEDED';
$$;

revoke all on function public._po_xendit_paid_total(text) from public, anon, authenticated;

-- A request's state, from its latest payout (live first): Awaiting approval / Sending / Paid / Paid (test) /
-- Failed / Cancelled.
create or replace function public._po_xendit_request_state(p_request_status text, p_payout_status text, p_is_test boolean)
returns text
language sql
immutable
as $$
  select case
    when p_request_status = 'Cancelled' then 'Cancelled'
    when p_payout_status is null then 'Awaiting approval'
    when p_payout_status in ('Creating', 'ACCEPTED', 'REQUESTED') then 'Sending'
    when p_payout_status = 'SUCCEEDED' then case when p_is_test then 'Paid (test)' else 'Paid' end
    else 'Failed'
  end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Staff RPCs (Purchase Orders page).

-- Request a payment. p_amount null = the whole balance left to request.
create or replace function public.staff_request_po_xendit_payment(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_amount numeric,
  p_is_down_payment boolean,
  p_note text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_po record;
  v_vendor record;
  v_total numeric;
  v_requested numeric;
  v_left numeric;
  v_amount numeric;
  v_note text := left(nullif(trim(coalesce(p_note, '')), ''), 200);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select * into v_po from public."PurchaseOrders" where "PONo" = p_po_no for update;
  if not found then
    return query select false, ('Purchase Order ' || p_po_no || ' not found - it may already be posted.')::text;
    return;
  end if;

  select * into v_vendor from public."Vendors" where "VendorCode" = v_po."VendorCode";
  if v_vendor."PayoutChannelCode" is null or v_vendor."PayoutAccountNumber" is null or v_vendor."PayoutAccountName" is null then
    return query select false, ('No Xendit payout account for ' || coalesce(v_vendor."Name", v_po."VendorCode")
                                || ' yet - a super user adds it on Vendors > Manage.')::text;
    return;
  end if;

  v_total := public._po_ordered_total(p_po_no);
  if v_total <= 0 then
    return query select false, 'This Purchase Order has no cost yet - enter the Unit Costs first.'::text;
    return;
  end if;

  select coalesce(sum(r."Amount"), 0) into v_requested
    from public."PurchaseOrderXenditRequests" r where r."PONo" = p_po_no and r."Status" <> 'Cancelled';
  v_left := v_total - v_requested;

  v_amount := round(coalesce(p_amount, v_left), 2);
  if v_amount <= 0 then
    return query select false, (case when v_left <= 0 then 'The whole PO total (' || to_char(v_total, 'FM999,999,990.00') || ') is already requested.'
                                     else 'Enter an amount above zero.' end)::text;
    return;
  end if;
  if v_amount > v_left then
    return query select false, ('That is more than what is left to pay: ' || to_char(v_left, 'FM999,999,990.00') || ' of '
                                || to_char(v_total, 'FM999,999,990.00') || '.')::text;
    return;
  end if;

  insert into public."PurchaseOrderXenditRequests" ("PONo", "VendorCode", "Amount", "IsDownPayment", "Note", "RequestedBy")
  values (p_po_no, v_po."VendorCode", v_amount, coalesce(p_is_down_payment, false) and v_amount < v_left, v_note, p_admin_username);

  -- Nothing picked yet: this PO is being paid through Xendit.
  if v_po."PaymentMethod" is null then
    update public."PurchaseOrders" set "PaymentMethod" = 'Xendit' where "PONo" = p_po_no;
  end if;

  perform public._telegram_send_message(
    'Purchase Order ' || p_po_no || ' (' || coalesce(v_vendor."Name", v_po."VendorCode") || E'):\n'
    || p_admin_username || ' requests a Xendit payment of PHP ' || to_char(v_amount, 'FM999,999,990.00')
    || case when coalesce(p_is_down_payment, false) and v_amount < v_left then ' (down payment)' else '' end
    || ' to ' || coalesce(v_vendor."PayoutChannelName", v_vendor."PayoutChannelCode") || ' ••' || right(v_vendor."PayoutAccountNumber", 4)
    || ' (' || v_vendor."PayoutAccountName" || ').'
    || case when v_note is not null then E'\nNote: ' || v_note else '' end
    || E'\nA super user approves it on the Purchase Order > Xendit Payments.');

  return query select true, 'Payment requested - a super user can now approve and send it.'::text;
end;
$$;

grant execute on function public.staff_request_po_xendit_payment(text, text, text, numeric, boolean, text) to anon;

-- Cancel a request that has no live money going out or paid. The requester or a super user.
create or replace function public.staff_cancel_po_xendit_payment(p_admin_username text, p_admin_password text, p_request_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_req public."PurchaseOrderXenditRequests"%rowtype;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select * into v_req from public."PurchaseOrderXenditRequests" where "RequestID" = p_request_id for update;
  if not found then
    return query select false, 'Payment request not found.'::text;
    return;
  end if;
  if v_req."Status" = 'Cancelled' then
    return query select true, 'Already cancelled.'::text;
    return;
  end if;
  if v_req."RequestedBy" <> p_admin_username and not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Only the person who requested it or a super user can cancel it.'::text;
    return;
  end if;
  if exists (select 1 from public."XenditPayouts" x
             where x."VendorRequestID" = p_request_id and not x."IsTest"
               and x."Status" in ('Creating', 'ACCEPTED', 'REQUESTED', 'SUCCEEDED')) then
    return query select false, 'This payment was already sent through Xendit, so it can''t be cancelled.'::text;
    return;
  end if;

  update public."PurchaseOrderXenditRequests"
     set "Status" = 'Cancelled', "CancelledBy" = p_admin_username, "CancelledAtUtc" = now()
   where "RequestID" = p_request_id;

  return query select true, 'Payment request cancelled.'::text;
end;
$$;

grant execute on function public.staff_cancel_po_xendit_payment(text, text, uuid) to anon;

-- Everything the PO card's Xendit Payments section shows, as one JSON object.
create or replace function public.staff_get_po_xendit_payments(p_admin_username text, p_admin_password text, p_po_no text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_po record;
  v_vendor record;
  v_requests jsonb;
  v_requested numeric;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_po from public."PurchaseOrders" where "PONo" = p_po_no;
  if not found then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;
  select * into v_vendor from public."Vendors" where "VendorCode" = v_po."VendorCode";

  select coalesce(sum(r."Amount"), 0) into v_requested
    from public."PurchaseOrderXenditRequests" r where r."PONo" = p_po_no and r."Status" <> 'Cancelled';

  select coalesce(jsonb_agg(jsonb_build_object(
           'request_id', r."RequestID",
           'amount', r."Amount",
           'is_down_payment', r."IsDownPayment",
           'note', r."Note",
           'requested_by', coalesce(rb."DisplayName", r."RequestedBy"),
           'requested_by_username', r."RequestedBy",
           'requested_at', r."RequestedAtUtc",
           'cancelled_by', r."CancelledBy",
           'cancelled_at', r."CancelledAtUtc",
           'state', public._po_xendit_request_state(r."Status", p."Status", p."IsTest"),
           'payout_status', p."Status",
           'is_test', p."IsTest",
           'failure', coalesce(p."FailureCode", p."Error"),
           'sent_by', coalesce(sb."DisplayName", p."SentBy"),
           'sent_at', p."CreatedAtUtc",
           'paid_at', p."PaidAtUtc",
           'xendit_payout_id', p."XenditPayoutID",
           'paid_to', case when p."PayoutID" is null then null
                           else coalesce(p."ChannelName", p."ChannelCode") || ' ••' || right(p."AccountNumber", 4) end,
           'live_locked', exists (select 1 from public."XenditPayouts" x
                                  where x."VendorRequestID" = r."RequestID" and not x."IsTest"
                                    and x."Status" in ('Creating', 'ACCEPTED', 'REQUESTED', 'SUCCEEDED'))
         ) order by r."RequestedAtUtc"), '[]'::jsonb)
    into v_requests
    from public."PurchaseOrderXenditRequests" r
    left join lateral (
      select x.* from public."XenditPayouts" x where x."VendorRequestID" = r."RequestID"
      order by x."IsTest", x."CreatedAtUtc" desc limit 1
    ) p on true
    left join public."StaffUsers" rb on rb."Username" = r."RequestedBy"
    left join public."StaffUsers" sb on sb."Username" = p."SentBy"
    where r."PONo" = p_po_no;

  return jsonb_build_object(
    'po_no', p_po_no,
    'vendor_code', v_po."VendorCode",
    'vendor_name', v_vendor."Name",
    'vendor_email', v_vendor."Email",
    'has_account', v_vendor."PayoutChannelCode" is not null and v_vendor."PayoutAccountNumber" is not null and v_vendor."PayoutAccountName" is not null,
    'account_channel', coalesce(v_vendor."PayoutChannelName", v_vendor."PayoutChannelCode"),
    'account_masked', case when v_vendor."PayoutAccountNumber" is null then null else '••' || right(v_vendor."PayoutAccountNumber", 4) end,
    'account_name', v_vendor."PayoutAccountName",
    'payment_method', v_po."PaymentMethod",
    'ordered_total', public._po_ordered_total(p_po_no),
    'requested_total', v_requested,
    'paid_total', public._po_xendit_paid_total(p_po_no),
    'requests', v_requests
  );
end;
$$;

grant execute on function public.staff_get_po_xendit_payments(text, text, text) to anon;

-- Purchase Orders list badges: per PO, how many requests are awaiting approval / sending / failed, and paid.
create or replace function public.staff_po_xendit_badges(p_admin_username text, p_admin_password text, p_po_nos text[])
returns table(po_no text, awaiting int, sending int, failed int, paid numeric)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s.po_no,
           count(*) filter (where s.state = 'Awaiting approval')::int,
           count(*) filter (where s.state = 'Sending')::int,
           count(*) filter (where s.state = 'Failed')::int,
           coalesce(sum(s.amount) filter (where s.state = 'Paid'), 0)::numeric
    from (
      select r."PONo"::text as po_no, r."Amount" as amount,
             public._po_xendit_request_state(r."Status", p."Status", p."IsTest") as state
      from public."PurchaseOrderXenditRequests" r
      left join lateral (
        select x."Status", x."IsTest" from public."XenditPayouts" x where x."VendorRequestID" = r."RequestID"
        order by x."IsTest", x."CreatedAtUtc" desc limit 1
      ) p on true
      where r."PONo" = any(coalesce(p_po_nos, '{}')) and r."Status" <> 'Cancelled'
    ) s
    group by s.po_no;
end;
$$;

grant execute on function public.staff_po_xendit_badges(text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- 5. Service-role helpers for the xendit-vendor-payout Edge Function.

-- The payout row for this request in this mode: a new one if nothing is going yet (account copied from Vendors
-- now), the same one again if it is stuck at 'Creating' (re-sent with the SAME Idempotency-key), or no row
-- (already sent / paid - the Edge Function reports it instead of paying twice).
create or replace function public._vendor_payout_prepare(p_request_id uuid, p_is_test boolean, p_sent_by text)
returns table(payout_id uuid, reference_id text, po_no text, vendor_name text, amount numeric, channel_code text,
              account_number text, account_name text, description text, email_to text, email_cc text, is_new boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_req public."PurchaseOrderXenditRequests"%rowtype;
  v_po record;
  v_vendor record;
  v_id uuid;
  v_status text;
  v_desc text;
  v_cc text;
  v_vendor_email text;
begin
  perform pg_advisory_xact_lock(hashtext('vendor-po-payout'));

  select * into v_req from public."PurchaseOrderXenditRequests" where "RequestID" = p_request_id for update;
  if not found then
    raise exception 'Payment request not found.';
  end if;
  if v_req."Status" = 'Cancelled' then
    raise exception 'This payment request was cancelled.';
  end if;

  v_desc := left('RS Pet Stop payment ' || v_req."PONo" || case when v_req."IsDownPayment" then ' (down payment)' else '' end, 100);

  select x."PayoutID", x."Status" into v_id, v_status from public."XenditPayouts" x
   where x."VendorRequestID" = p_request_id and x."IsTest" = p_is_test
     and x."Status" not in ('FAILED', 'CANCELLED', 'REVERSED', 'Error');
  if found then
    if v_status = 'Creating' then
      return query
        select x."PayoutID", x."ReferenceID", x."PONo", x."DisplayName", x."Amount", x."ChannelCode", x."AccountNumber",
               x."AccountName", v_desc, x."ReceiptEmailTo", x."ReceiptEmailCc", false
        from public."XenditPayouts" x where x."PayoutID" = v_id;
    end if;
    return;
  end if;

  -- A live payout already paid for this request: never a second one (a test one never blocks live).
  if not p_is_test and exists (select 1 from public."XenditPayouts" x
                               where x."VendorRequestID" = p_request_id and not x."IsTest" and x."Status" = 'SUCCEEDED') then
    return;
  end if;

  select * into v_po from public."PurchaseOrders" where "PONo" = v_req."PONo";
  if not found then
    raise exception 'Purchase Order % is no longer open - it may already be posted.', v_req."PONo";
  end if;
  if v_po."VendorCode" <> v_req."VendorCode" then
    raise exception 'The Purchase Order''s vendor changed since this was requested - cancel it and request again.';
  end if;

  select * into v_vendor from public."Vendors" where "VendorCode" = v_req."VendorCode";
  if v_vendor."PayoutChannelCode" is null or v_vendor."PayoutAccountNumber" is null or v_vendor."PayoutAccountName" is null then
    raise exception '% has no Xendit payout account - add it on Vendors > Manage.', coalesce(v_vendor."Name", v_req."VendorCode");
  end if;

  -- Xendit's emailed proof: to the vendor's Email, CC the records address (or the records address alone).
  select nullif(trim(ps."SettingValue"), '') into v_cc from public."PortalSettings" ps where ps."SettingKey" = 'XENDIT_PAYOUT_RECEIPT_CC';
  v_vendor_email := nullif(lower(trim(coalesce(v_vendor."Email", ''))), '');
  if v_vendor_email is not null and v_vendor_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' then
    v_vendor_email := null;
  end if;

  v_id := gen_random_uuid();
  insert into public."XenditPayouts" ("PayoutID", "ReferenceID", "Kind", "PONo", "VendorCode", "VendorRequestID", "DisplayName", "Amount",
                                      "ChannelCode", "ChannelName", "AccountNumber", "AccountName", "IsTest", "SentBy", "Note",
                                      "ReceiptEmailTo", "ReceiptEmailCc")
  values (v_id, 'RSPS-PAY-PO-' || replace(v_id::text, '-', ''), 'Vendor', v_req."PONo", v_req."VendorCode", p_request_id,
          left(coalesce(v_vendor."Name", v_req."VendorCode"), 100), v_req."Amount",
          v_vendor."PayoutChannelCode", v_vendor."PayoutChannelName", v_vendor."PayoutAccountNumber", v_vendor."PayoutAccountName",
          p_is_test, p_sent_by, v_req."Note",
          coalesce(v_vendor_email, v_cc), case when v_vendor_email is null then null else v_cc end);

  return query
    select x."PayoutID", x."ReferenceID", x."PONo", x."DisplayName", x."Amount", x."ChannelCode", x."AccountNumber",
           x."AccountName", v_desc, x."ReceiptEmailTo", x."ReceiptEmailCc", true
    from public."XenditPayouts" x where x."PayoutID" = v_id;
end;
$$;

revoke all on function public._vendor_payout_prepare(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public._vendor_payout_prepare(uuid, boolean, text) to service_role;

-- This PO's payouts still waiting on Xendit (for "Refresh Status").
create or replace function public._vendor_payouts_open(p_po_no text)
returns table(payout_id uuid, reference_id text, xendit_payout_id text, is_test boolean, status text, age_seconds numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select "PayoutID", "ReferenceID", "XenditPayoutID", "IsTest", "Status", extract(epoch from now() - "CreatedAtUtc")::numeric
  from public."XenditPayouts"
  where "Kind" = 'Vendor' and "PONo" = p_po_no and "Status" in ('Creating', 'ACCEPTED', 'REQUESTED');
$$;

revoke all on function public._vendor_payouts_open(text) from public, anon, authenticated;
grant execute on function public._vendor_payouts_open(text) to service_role;

-- ---------------------------------------------------------------------------
-- 6. A PO with live Xendit money out can't be deleted or merged away (posting deletes the row too - allowed,
--    the posted copy already exists by then). Requests not sent yet are cancelled with it.

create or replace function public._purchase_order_xendit_delete_guard()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if exists (select 1 from public."PostedPurchaseOrders" p where p."PONo" = old."PONo") then
    return old;
  end if;

  if exists (select 1 from public."XenditPayouts" x
             where x."Kind" = 'Vendor' and x."PONo" = old."PONo" and not x."IsTest"
               and x."Status" in ('Creating', 'ACCEPTED', 'REQUESTED', 'SUCCEEDED')) then
    raise exception 'Purchase Order % has a Xendit payment to the supplier (sent or paid), so it can''t be deleted or merged away - post it instead.', old."PONo";
  end if;

  update public."PurchaseOrderXenditRequests"
     set "Status" = 'Cancelled', "CancelledBy" = 'PO deleted', "CancelledAtUtc" = now()
   where "PONo" = old."PONo" and "Status" <> 'Cancelled';

  return old;
end;
$$;

drop trigger if exists "TR_PurchaseOrders_XenditDeleteGuard" on public."PurchaseOrders";
create trigger "TR_PurchaseOrders_XenditDeleteGuard"
before delete on public."PurchaseOrders"
for each row execute function public._purchase_order_xendit_delete_guard();

-- ---------------------------------------------------------------------------
-- 7. _create_vendor_payment (supabase_purchase_order_paid_on_post.sql) + 'xendit' credits Digital / Bank.

create or replace function public._create_vendor_payment(
  p_vendor_code text,
  p_bill_no text,
  p_payment_date date,
  p_amount numeric,
  p_method text,
  p_reference_no text,
  p_notes text,
  p_created_by text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_payment_no text;
  v_payable_account text;
  v_cash_account text;
  v_digital_account text;
  v_credit_account text;
  v_transaction_no bigint;
begin
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'Vendor payment amount must be greater than zero.';
  end if;

  select s."PayableAccountNo", s."CashAccountNo", s."DigitalAccountNo"
    into v_payable_account, v_cash_account, v_digital_account
  from public."GLSetup" s limit 1;

  -- Same rule as admin_create_vendor_payment: anything recognisably digital hits Digital / Bank.
  v_credit_account := case
    when lower(coalesce(p_method, '')) similar to '%(gcash|bank|transfer|digital|online|maya|card|xendit)%' then v_digital_account
    else v_cash_account
  end;

  if v_payable_account is null or v_credit_account is null then
    raise exception 'G/L Setup is incomplete - Accounts Payable and Cash/Digital accounts are required before payments can be recorded.';
  end if;

  v_payment_no := public._next_no_series_number('VENDOR-PAYMENT', '');

  insert into public."VendorPayments" ("PaymentNo", "VendorCode", "BillNo", "PaymentDate", "Amount", "Method", "ReferenceNo", "Notes", "CreatedBy")
  values (v_payment_no, p_vendor_code, nullif(trim(coalesce(p_bill_no, '')), ''), p_payment_date, p_amount,
          nullif(trim(coalesce(p_method, '')), ''), nullif(trim(coalesce(p_reference_no, '')), ''),
          nullif(trim(coalesce(p_notes, '')), ''), p_created_by);

  v_transaction_no := public._gl_post(
    p_payment_date,
    'Vendor Payment',
    v_payment_no,
    'Payment ' || v_payment_no || ' - ' || p_vendor_code,
    'Vendor',
    p_vendor_code,
    jsonb_build_array(
      jsonb_build_object('account_no', v_payable_account, 'amount', p_amount),
      jsonb_build_object('account_no', v_credit_account, 'amount', -p_amount)
    ),
    p_created_by
  );

  update public."VendorPayments" set "GLTransactionNo" = v_transaction_no where "PaymentNo" = v_payment_no;

  return v_payment_no;
end;
$$;

revoke execute on function public._create_vendor_payment(text, text, date, numeric, text, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. staff_post_purchase_order: supabase_purchase_order_paid_on_post.sql's version, but the bill is paid from
--    the PO's live Xendit payouts first, then the rest by the Payment Method.

create or replace function public.staff_post_purchase_order(
  p_admin_username text,
  p_admin_password text,
  p_po_no text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_header record;
  v_bill_total numeric;
  v_inventory_account text;
  v_bill record;
  v_xendit_paid numeric;
  v_left numeric;
  v_apply numeric;
  v_payout record;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_header from public."PurchaseOrders" where "PONo" = p_po_no for update;

  if not found then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  -- Every Xendit request must be settled: paid (live), or cancelled.
  if exists (
    select 1 from public."PurchaseOrderXenditRequests" r
    where r."PONo" = p_po_no and r."Status" <> 'Cancelled'
      and not exists (select 1 from public."XenditPayouts" x
                      where x."VendorRequestID" = r."RequestID" and not x."IsTest" and x."Status" = 'SUCCEEDED')) then
    raise exception 'Cannot post - this Purchase Order has a Xendit payment that isn''t paid yet (awaiting approval, sending or failed). Wait for it, or cancel it, first.';
  end if;

  select coalesce(sum(round(coalesce("UnitCost", 0) * coalesce("QtyReceived", 0), 2)), 0)
    into v_bill_total
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no;

  v_xendit_paid := public._po_xendit_paid_total(p_po_no);

  if v_bill_total > v_xendit_paid then
    if v_header."PaymentMethod" is null then
      raise exception 'Cannot post - set a Payment Method for this Purchase Order first.';
    end if;
    if v_header."PaymentMethod" = 'Xendit' then
      raise exception 'Cannot post - Xendit has paid % of the % received. Request the remaining % through Xendit, or set the Payment Method to Cash or Online for the rest.',
        to_char(v_xendit_paid, 'FM999,999,990.00'), to_char(v_bill_total, 'FM999,999,990.00'), to_char(v_bill_total - v_xendit_paid, 'FM999,999,990.00');
    end if;
  end if;

  insert into public."PostedPurchaseOrders" ("PONo", "VendorCode", "OrderDate", "Notes", "CreatedBy", "CreatedAtUtc", "PostedBy")
  select "PONo", "VendorCode", "OrderDate", "Notes", "CreatedBy", "CreatedAtUtc", p_admin_username
  from public."PurchaseOrders"
  where "PONo" = p_po_no;

  insert into public."PostedPurchaseOrderLines" ("PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived", "Description", "UnitCost")
  select "PONo", "ItemCode", "ItemName", "WarehouseId", "WarehouseName", "Quantity", "QtyReceived", "Description", "UnitCost"
  from public."PurchaseOrderLines"
  where "PONo" = p_po_no;

  update public."Items" i
     set "Cost" = latest."UnitCost"
    from (
      select distinct on ("ItemCode") "ItemCode", "UnitCost"
      from public."PurchaseOrderLines"
      where "PONo" = p_po_no
        and "UnitCost" is not null
        and coalesce("QtyReceived", 0) > 0
      order by "ItemCode", "EntryNo" desc
    ) as latest
   where i."Code" = latest."ItemCode";

  delete from public."PurchaseOrders" where "PONo" = p_po_no;

  v_left := 0;
  if v_bill_total > 0 then
    select s."InventoryAccountNo" into v_inventory_account from public."GLSetup" s limit 1;

    -- Goods bought for resale are an asset until sold, so a purchase debits Inventory, not an
    -- expense account. The internal helper, not admin_create_vendor_bill: posting a PO is
    -- is_staff_authorized, so the super-user wrapper would fail for ordinary staff.
    select * into v_bill from public._create_vendor_bill(
      v_header."VendorCode",
      v_header."OrderDate",
      null,
      p_po_no,
      v_bill_total,
      'Auto-raised on posting Purchase Order ' || p_po_no,
      v_inventory_account,
      p_po_no,
      p_admin_username
    );

    -- _create_vendor_bill reports failure in its result rather than raising; raising here rolls the
    -- entire posting back so a PO never posts without its bill.
    if not v_bill.success then
      raise exception 'Purchase Order was not posted - could not raise the vendor bill: %', v_bill.message;
    end if;
    v_left := v_bill_total;
  end if;

  -- Xendit payouts first, oldest first, each one its own vendor payment (dated the day Xendit paid it, in
  -- Manila). Whatever is above the bill stays on the vendor as a credit (not applied to a bill).
  for v_payout in
    select x."Amount", x."XenditPayoutID", x."ReferenceID", coalesce(x."PaidAtUtc", x."CreatedAtUtc") as paid_at
    from public."XenditPayouts" x
    where x."Kind" = 'Vendor' and x."PONo" = p_po_no and not x."IsTest" and x."Status" = 'SUCCEEDED'
    order by coalesce(x."PaidAtUtc", x."CreatedAtUtc")
  loop
    v_apply := least(v_payout."Amount", v_left);
    if v_apply > 0 then
      perform public._create_vendor_payment(
        v_header."VendorCode", v_bill.bill_no, (v_payout.paid_at at time zone 'Asia/Manila')::date, v_apply, 'Xendit',
        coalesce(v_payout."XenditPayoutID", v_payout."ReferenceID"),
        'Paid through Xendit for Purchase Order ' || p_po_no, p_admin_username);
      v_left := v_left - v_apply;
    end if;
    if v_payout."Amount" - v_apply > 0 then
      perform public._create_vendor_payment(
        v_header."VendorCode", null, (v_payout.paid_at at time zone 'Asia/Manila')::date, v_payout."Amount" - v_apply, 'Xendit',
        coalesce(v_payout."XenditPayoutID", v_payout."ReferenceID"),
        'Paid through Xendit for Purchase Order ' || p_po_no || ' above what was received - vendor credit', p_admin_username);
    end if;
  end loop;

  -- Pay first, then receive: the rest of the bill is settled in the same transaction (Dr Accounts Payable,
  -- Cr Cash / Digital by the PO's Payment Method).
  if v_left > 0 then
    perform public._create_vendor_payment(
      v_header."VendorCode",
      v_bill.bill_no,
      v_header."OrderDate",
      v_left,
      v_header."PaymentMethod",
      p_po_no,
      'Paid on posting Purchase Order ' || p_po_no,
      p_admin_username
    );
  end if;
end;
$$;

grant execute on function public.staff_post_purchase_order(text, text, text) to anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Check - one result.
select 'vendor payout columns' as section,
       case when exists (select 1 from information_schema.columns where table_name = 'Vendors' and column_name = 'PayoutAccountNumber')
            then 'ready' else 'MISSING' end as value
union all
select 'payment method Xendit',
       case when pg_get_constraintdef((select oid from pg_constraint where conname = 'CK_PurchaseOrders_PaymentMethod')) like '%Xendit%'
            then 'allowed' else 'MISSING' end
union all
select 'payout kind Vendor',
       case when pg_get_constraintdef((select oid from pg_constraint where conname = 'CK_XenditPayouts_Kind')) like '%Vendor%'
             and pg_get_constraintdef((select oid from pg_constraint where conname = 'CK_XenditPayouts_Kind')) like '%Owner%'
            then 'allowed (Owner kept)' else 'MISSING' end
union all
select 'edge function helpers',
       case when to_regprocedure('public._vendor_payout_prepare(uuid, boolean, text)') is not null
             and to_regprocedure('public._vendor_payouts_open(text)') is not null then 'ready' else 'MISSING' end
union all
select 'post uses Xendit payouts',
       case when pg_get_functiondef('public.staff_post_purchase_order(text, text, text)'::regprocedure) like '%_po_xendit_paid_total%'
            then 'yes' else 'OLD version' end
union all
select 'delete guard trigger',
       case when exists (select 1 from pg_trigger where tgname = 'TR_PurchaseOrders_XenditDeleteGuard') then 'ready' else 'MISSING' end
union all
select 'vendors with a payout account', count(*)::text from public."Vendors" where "PayoutAccountNumber" is not null;
