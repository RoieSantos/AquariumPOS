-- Advance orders paid on the PORTAL - per "how can we fully paid a advance order in the portal" /
-- "once the delivery team remitted the order tag the payment, also allow a super user to fully paid the order".
--
-- Until now an advance order's balance could only be paid in the POS (AdvanceOrdersHeaderForm Pay In Full);
-- a driver's collection on an advance order was 'Record only'. Now:
--   1. Delivery remit: when a Super User marks a driver's collection Remitted (Delivery page, day's
--      Collections list), a collection on an advance order goes onto the order as a portal payment
--      (admin_remit_delivery_collections). Retry re-applies a Failed one.
--   2. Super User "Mark Fully Paid" on the Advance Order card (Online Orders, Advance tab): pays the whole
--      remaining balance with a payment method + optional reference (admin_advance_order_mark_fully_paid).
--
-- Each one is a row in AdvanceOrderPortalPayments. The POS still pushes every advance order header every
-- 5 minutes with ITS Downpayment / Balance / FullyPaid, which know nothing about portal payments - so a
-- BEFORE trigger on AdvanceOrders (TR_AdvanceOrders_PortalPayments) adds them back on every write:
--   PosDownpayment = what the POS last sent (a write that moves "SyncedAtUtc" is the POS push)
--   Downpayment    = PosDownpayment + portal payments the POS hasn't taken in yet (capped at NetAmount)
--   Balance        = NetAmount - Downpayment;  FullyPaid / DatePaid set once it reaches 0.
-- It runs before zz_skip_noop_sync_update (name order), so an unchanged POS push is still skipped.
--
-- The POS (AdvanceOrdersHeaderForm Pay In Full, updated build) first asks pos_get_advance_order_portal_payments:
-- anything paid on the portal is written onto its local AdvanceOrderHeader (a 'PAYMENT' line "Paid on portal",
-- no cash-drawer entry - the money didn't go through the POS) and acknowledged with
-- pos_ack_advance_order_portal_payments, so the cashier can never collect it again. Older POS builds don't
-- ask - the portal still shows the order paid, but the POS's own list keeps its old balance.
--
-- Portal payments also go into AdvanceOrderPayments (PaymentTransactionNo 'PORTAL-...'), so the Dashboard's
-- "Collected today - by tender" split counts them.
--
-- Run AFTER supabase_delivery_driver_collections.sql, supabase_advance_order_payments.sql,
-- supabase_advance_orders_paid_status_fields.sql, supabase_advance_order_void.sql and
-- supabase_skip_noop_sync_updates.sql. Safe to re-run. Ends with ONE result: OK / FIX.
-- Needs js/onlineOrders.js ?v=advpay1 and js/delivery.js ?v=advpay1 (reload the pages after running).

set lock_timeout = '10s';

-- ============================================================================
-- 1. Table + AdvanceOrders columns
-- ============================================================================
create table if not exists public."AdvanceOrderPortalPayments" (
  "PaymentID" uuid primary key,              -- made by the page (Mark Fully Paid) or = CollectionID (remit)
  "TransactionNo" varchar(100) not null,     -- AdvanceOrders."TransactionNo"
  "Amount" numeric(18, 2) not null check ("Amount" > 0),
  "MethodCode" text,                         -- PaymentMethods.Code
  "MethodName" text not null,
  "Reference" text,
  "Source" text not null,                    -- 'Delivery remit' / 'Super User'
  "CollectionID" uuid unique,                -- DeliveryCollections row it came from (remit)
  "RecordedBy" text not null,
  "RecordedAtUtc" timestamptz not null default now(),
  "PosAbsorbedAtUtc" timestamptz             -- the POS wrote it onto its local order (then it's in PosDownpayment)
);
create index if not exists "IX_AdvanceOrderPortalPayments_No" on public."AdvanceOrderPortalPayments" ("TransactionNo");
alter table public."AdvanceOrderPortalPayments" enable row level security;   -- no policies: RPCs only
revoke all on public."AdvanceOrderPortalPayments" from anon, authenticated;

alter table public."AdvanceOrders" add column if not exists "PosDownpayment" numeric(18, 2);
alter table public."AdvanceOrders" add column if not exists "PortalPaid" numeric(18, 2) not null default 0;

-- ============================================================================
-- 2. Keep portal payments on the order through every POS push
-- ============================================================================
create or replace function public._advance_order_portal_payments_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_portal numeric;
  v_last timestamptz;
begin
  select coalesce(sum(p."Amount"), 0), max(p."RecordedAtUtc") into v_portal, v_last
  from public."AdvanceOrderPortalPayments" p
  where p."TransactionNo" = new."TransactionNo" and p."PosAbsorbedAtUtc" is null;

  -- Never had a portal payment: leave the row exactly as written (no extra writes on the POS push).
  if v_portal = 0 and (tg_op = 'INSERT' or old."PosDownpayment" is null) then
    new."PortalPaid" := 0;
    return new;
  end if;

  if tg_op = 'INSERT' or new."SyncedAtUtc" is distinct from old."SyncedAtUtc" then
    new."PosDownpayment" := new."Downpayment";                          -- the POS push: its own figure
  elsif new."PosDownpayment" is not distinct from old."PosDownpayment" then
    -- a portal write; pos_ack_advance_order_portal_payments sets PosDownpayment itself and is kept
    new."PosDownpayment" := coalesce(old."PosDownpayment", old."Downpayment");
  end if;
  new."PortalPaid" := v_portal;
  if v_portal = 0 then
    return new;
  end if;

  new."Downpayment" := least(coalesce(new."NetAmount", 0), coalesce(new."PosDownpayment", 0) + v_portal);
  new."Balance" := greatest(coalesce(new."NetAmount", 0) - new."Downpayment", 0);
  if new."Balance" <= 0 then
    new."FullyPaid" := true;
    new."DatePaid" := coalesce(new."DatePaid", case when tg_op = 'UPDATE' then old."DatePaid" end, v_last);
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_AdvanceOrders_PortalPayments" on public."AdvanceOrders";
create trigger "TR_AdvanceOrders_PortalPayments"
  before insert or update on public."AdvanceOrders"
  for each row execute function public._advance_order_portal_payments_trigger();

-- ============================================================================
-- 3. Add one portal payment (shared by remit + Mark Fully Paid). Returns the amount put on the order
--    (0 = nothing owed). Same p_payment_id again = no second payment.
-- ============================================================================
create or replace function public._advance_order_add_portal_payment(
  p_payment_id uuid,
  p_no text,
  p_amount numeric,
  p_method_code text,
  p_method_name text,
  p_reference text,
  p_source text,
  p_collection_id uuid,
  p_by text
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  a public."AdvanceOrders"%rowtype;
  v_existing numeric;
  v_apply numeric;
  v_now_mnl timestamp := now() at time zone 'Asia/Manila';
begin
  select "Amount" into v_existing from public."AdvanceOrderPortalPayments" where "PaymentID" = p_payment_id;
  if found then
    return v_existing;
  end if;

  select * into a from public."AdvanceOrders" where "TransactionNo" = p_no for update;
  if not found then
    raise exception 'Advance order % is not on the portal.', p_no;
  end if;
  if coalesce(a."IsVoid", false) then
    raise exception 'Advance order % was voided - it can''t be paid.', p_no;
  end if;

  v_apply := round(least(coalesce(p_amount, 0), greatest(coalesce(a."Balance", 0), 0)), 2);
  if v_apply <= 0 then
    return 0;
  end if;

  insert into public."AdvanceOrderPortalPayments"
    ("PaymentID", "TransactionNo", "Amount", "MethodCode", "MethodName", "Reference", "Source", "CollectionID", "RecordedBy")
  values (p_payment_id, p_no, v_apply, p_method_code, p_method_name,
          nullif(left(trim(coalesce(p_reference, '')), 200), ''), p_source, p_collection_id, p_by);

  -- Dashboard "Collected today - by tender".
  insert into public."AdvanceOrderPayments"
    ("AdvanceTransactionNo", "PaymentTransactionNo", "TenderTypeCode", "LineNo", "ReceiptNo", "Description",
     "Amount", "UserID", "Date", "Time", "Warehouse", "SyncedAtUtc")
  values (p_no, 'PORTAL-' || left(p_payment_id::text, 8),
          case when p_method_code = 'CASH' then 'CASH' else left(upper(trim(p_method_name)), 50) end,
          '1', a."ReceiptNo", left('Portal - ' || p_source || ' - ' || p_method_name, 500),
          v_apply, left(p_by, 100), v_now_mnl::date, to_char(v_now_mnl, 'HH24:MI:SS'), a."Warehouse", now())
  on conflict do nothing;

  -- Recompute the order (TR_AdvanceOrders_PortalPayments does the maths).
  update public."AdvanceOrders" set "PortalPaid" = "PortalPaid" where "TransactionNo" = p_no;
  return v_apply;
end;
$$;

revoke all on function public._advance_order_add_portal_payment(uuid, text, numeric, text, text, text, text, uuid, text) from public, anon, authenticated;

-- ============================================================================
-- 4. Super User: Mark Fully Paid (whole remaining balance)
-- ============================================================================
drop function if exists public.admin_advance_order_mark_fully_paid(text, text, uuid, text, text, text);

create or replace function public.admin_advance_order_mark_fully_paid(
  p_admin_username text,
  p_admin_password text,
  p_payment_id uuid,
  p_no text,
  p_method_code text,
  p_reference text
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method_name text;
  v_balance numeric;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User can mark an advance order paid.';
  end if;
  if p_payment_id is null or nullif(trim(coalesce(p_no, '')), '') is null then
    raise exception 'Payment ID and order are required.';
  end if;
  select coalesce(nullif(trim(pm."Name"), ''), nullif(trim(pm."PancakeName"), ''), 'Cash') into v_method_name
  from public."PaymentMethods" pm where pm."Code" = p_method_code and pm."IsActive";
  if v_method_name is null then
    raise exception 'Pick a payment method.';
  end if;

  if exists (select 1 from public."AdvanceOrderPortalPayments" where "PaymentID" = p_payment_id) then
    return (select "Amount" from public."AdvanceOrderPortalPayments" where "PaymentID" = p_payment_id);
  end if;
  select "Balance" into v_balance from public."AdvanceOrders" where "TransactionNo" = trim(p_no);
  if coalesce(v_balance, 0) <= 0 then
    raise exception 'Advance order % has no balance left.', trim(p_no);
  end if;

  return public._advance_order_add_portal_payment(p_payment_id, trim(p_no), v_balance, p_method_code, v_method_name,
                                                   p_reference, 'Super User', null, p_admin_username);
end;
$$;

grant execute on function public.admin_advance_order_mark_fully_paid(text, text, uuid, text, text, text) to anon;

-- Portal payments on one order (Advance Order card).
drop function if exists public.staff_list_advance_order_portal_payments(text, text, text);

create or replace function public.staff_list_advance_order_portal_payments(p_admin_username text, p_admin_password text, p_no text)
returns table(payment_id uuid, amount numeric, method_name text, reference text, source text,
              recorded_by text, recorded_at_utc timestamptz, pos_absorbed_at_utc timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select p."PaymentID", p."Amount", p."MethodName", p."Reference", p."Source",
           coalesce(u."DisplayName", p."RecordedBy")::text, p."RecordedAtUtc", p."PosAbsorbedAtUtc"
    from public."AdvanceOrderPortalPayments" p
    left join public."StaffUsers" u on u."Username" = p."RecordedBy"
    where p."TransactionNo" = trim(p_no)
    order by p."RecordedAtUtc";
end;
$$;

grant execute on function public.staff_list_advance_order_portal_payments(text, text, text) to anon;

-- ============================================================================
-- 5. Delivery remit -> the advance order's payment
-- ============================================================================
-- Put a remitted advance-order collection on its order. Never raises: the outcome lands on the collection.
create or replace function public._apply_advance_collection_on_remit(p_collection_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c public."DeliveryCollections"%rowtype;
  v_no text;
  v_apply numeric;
begin
  select * into c from public."DeliveryCollections" where "CollectionID" = p_collection_id for update;
  if not found or c."RemittedAtUtc" is null or c."ApplyStatus" = 'Applied' then
    return;
  end if;
  select s."AdvanceTransactionNo" into v_no from public."DeliveryStops" s where s."StopID" = c."StopID";
  if v_no is null then
    return;
  end if;

  begin
    v_apply := public._advance_order_add_portal_payment(c."CollectionID", v_no, c."Amount", c."MethodCode", c."MethodName",
      left('Delivery - collected by ' || c."CollectedBy" || coalesce(' - ' || nullif(trim(c."Reference"), ''), ''), 200),
      'Delivery remit', c."CollectionID", coalesce(c."RemittedBy", c."CollectedBy"));
    update public."DeliveryCollections"
    set "ApplyStatus" = 'Applied', "AppliedAmount" = v_apply, "ApplyError" = null,
        "AppliedIn" = case when v_apply > 0 then 'Advance order (on remit)' else 'Advance order - nothing owed' end,
        "AppliedAtUtc" = now()
    where "CollectionID" = c."CollectionID";
  exception when others then
    update public."DeliveryCollections"
    set "ApplyStatus" = 'Failed', "AppliedAmount" = 0, "ApplyError" = left(sqlerrm, 500)
    where "CollectionID" = c."CollectionID";
  end;
end;
$$;

revoke all on function public._apply_advance_collection_on_remit(uuid) from public, anon, authenticated;

-- (copy of supabase_delivery_driver_collections.sql's version + the advance-order step)
drop function if exists public.admin_remit_delivery_collections(text, text, uuid[]);

create or replace function public.admin_remit_delivery_collections(p_admin_username text, p_admin_password text, p_collection_ids uuid[])
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_count int;
  v_id uuid;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User can mark collections remitted.';
  end if;
  update public."DeliveryCollections"
  set "RemittedBy" = p_admin_username, "RemittedAtUtc" = now()
  where "CollectionID" = any(p_collection_ids) and "RemittedAtUtc" is null;
  get diagnostics v_count = row_count;

  -- Advance orders: the remitted money is now the order's payment.
  for v_id in
    select dc."CollectionID" from public."DeliveryCollections" dc
    join public."DeliveryStops" s on s."StopID" = dc."StopID"
    where dc."CollectionID" = any(p_collection_ids) and s."AdvanceTransactionNo" is not null
      and dc."RemittedAtUtc" is not null and dc."ApplyStatus" <> 'Applied'
  loop
    perform public._apply_advance_collection_on_remit(v_id);
  end loop;
  return v_count;
end;
$$;

grant execute on function public.admin_remit_delivery_collections(text, text, uuid[]) to anon;

-- Retry (copy of supabase_delivery_driver_collections.sql's version): a remitted advance-order collection
-- re-applies on its order instead of going back to 'Record only'.
drop function if exists public.staff_retry_delivery_collection(text, text, uuid);

create or replace function public.staff_retry_delivery_collection(p_username text, p_password text, p_collection_id uuid)
returns table(apply_status text, apply_error text, applied_amount numeric, applied_in text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '120000'
as $$
declare
  v_stop uuid;
  v_remitted timestamptz;
  v_advance text;
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  select dc."StopID", dc."RemittedAtUtc", s."AdvanceTransactionNo" into v_stop, v_remitted, v_advance
  from public."DeliveryCollections" dc
  left join public."DeliveryStops" s on s."StopID" = dc."StopID"
  where dc."CollectionID" = p_collection_id;
  if v_stop is null then
    raise exception 'Collection not found.';
  end if;
  perform pg_advisory_xact_lock(hashtext('delivery-collection:' || v_stop::text));
  if v_advance is not null and v_remitted is not null then
    perform public._apply_advance_collection_on_remit(p_collection_id);
  else
    perform public._apply_delivery_collection(p_collection_id);
  end if;
  return query
    select dc."ApplyStatus", dc."ApplyError", dc."AppliedAmount", dc."AppliedIn"
    from public."DeliveryCollections" dc where dc."CollectionID" = p_collection_id;
end;
$$;

grant execute on function public.staff_retry_delivery_collection(text, text, uuid) to anon;

-- ============================================================================
-- 6. POS: take portal payments onto the local order (Pay In Full asks first)
-- ============================================================================
-- Portal payments the POS hasn't written locally yet. Same no-login access as pos_check_advance_order_void.
create or replace function public.pos_get_advance_order_portal_payments(p_transaction_no text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return coalesce((
    select jsonb_build_object(
      'ok', true,
      'amount', coalesce(sum(p."Amount"), 0),
      'payment_ids', coalesce(jsonb_agg(p."PaymentID" order by p."RecordedAtUtc"), '[]'::jsonb),
      'detail', string_agg(p."MethodName" || ' ' || to_char(p."Amount", 'FM999,999,990.00') || ' (' || p."Source" || ', '
                           || p."RecordedBy" || ', ' || to_char(p."RecordedAtUtc" at time zone 'Asia/Manila', 'Mon DD HH12:MI AM') || ')',
                           '; ' order by p."RecordedAtUtc"))
    from public."AdvanceOrderPortalPayments" p
    where p."TransactionNo" = trim(coalesce(p_transaction_no, '')) and p."PosAbsorbedAtUtc" is null
  ), jsonb_build_object('ok', true, 'amount', 0, 'payment_ids', '[]'::jsonb));
end;
$$;

grant execute on function public.pos_get_advance_order_portal_payments(text) to anon;

-- The POS wrote these onto its local order: from now on its own Downpayment includes them.
create or replace function public.pos_ack_advance_order_portal_payments(p_transaction_no text, p_payment_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_no text := trim(coalesce(p_transaction_no, ''));
  v_amount numeric;
begin
  perform 1 from public."AdvanceOrders" where "TransactionNo" = v_no for update;
  with acked as (
    update public."AdvanceOrderPortalPayments"
    set "PosAbsorbedAtUtc" = now()
    where "TransactionNo" = v_no and "PaymentID" = any(p_payment_ids) and "PosAbsorbedAtUtc" is null
    returning "Amount"
  )
  select coalesce(sum("Amount"), 0) into v_amount from acked;

  if v_amount > 0 then
    -- Not a POS push (SyncedAtUtc unchanged), so the trigger keeps PosDownpayment as set here.
    update public."AdvanceOrders"
    set "PosDownpayment" = least(coalesce("NetAmount", 0), coalesce("PosDownpayment", "Downpayment", 0) + v_amount)
    where "TransactionNo" = v_no;
  end if;
  return jsonb_build_object('ok', true, 'amount', v_amount);
end;
$$;

grant execute on function public.pos_ack_advance_order_portal_payments(text, uuid[]) to anon;

notify pgrst, 'reload schema';

-- ============================================================================
-- Verification - one result
-- ============================================================================
select 'table' as section, 'AdvanceOrderPortalPayments' as item,
       case when to_regclass('public."AdvanceOrderPortalPayments"') is not null then 'OK' else 'FIX' end as status
union all
select 'trigger', 'TR_AdvanceOrders_PortalPayments',
       case when exists (select 1 from pg_trigger where tgrelid = 'public."AdvanceOrders"'::regclass
                           and tgname = 'TR_AdvanceOrders_PortalPayments' and tgenabled <> 'D') then 'OK' else 'FIX' end
union all
select 'function', f, case when to_regprocedure(f) is not null then 'OK' else 'FIX' end
from unnest(array[
  'public.admin_advance_order_mark_fully_paid(text,text,uuid,text,text,text)',
  'public.staff_list_advance_order_portal_payments(text,text,text)',
  'public.admin_remit_delivery_collections(text,text,uuid[])',
  'public.staff_retry_delivery_collection(text,text,uuid)',
  'public.pos_get_advance_order_portal_payments(text)',
  'public.pos_ack_advance_order_portal_payments(text,uuid[])'
]) f
union all
select 'portal payments so far', count(*)::text || ' payment(s)', 'OK' from public."AdvanceOrderPortalPayments";
