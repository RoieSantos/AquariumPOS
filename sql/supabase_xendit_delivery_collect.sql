-- Xendit QR for the delivery team - per "our delivery team sometimes can ask for payments once delivered..
-- since xendit is live how can we implement it?" (Option A: the driver shows a QR on their phone).
--
-- Flow:
--   1. On a stop with a balance, the driver taps "Collect by QR (GCash / Maya / bank)" in the Payment Collected
--      screen (Delivery page, Driver Route View). The page calls the Edge Function xendit-delivery-payment, which
--      checks the staff login, makes a QR Ph payment request for the amount (_xendit_delivery_prepare) and the
--      driver's phone shows the QR. The customer scans it with GCash, Maya or their bank app.
--   2. When Xendit says Paid (the page's status poll OR the xendit-webhook, whichever is first), the trigger
--      TR_XenditPayments_DeliveryPaid runs _xendit_delivery_complete once:
--        - saves a DeliveryCollections row per order on the stop (a combined drop is split across its orders,
--          each up to what it still owes - same as the manual split), method XENDIT ('Xendit' / 'Xendit TEST'),
--        - marks it Remitted by 'Xendit' straight away: the money is in the Xendit balance, never in the
--          driver's hand, so it never shows as "With driver" cash,
--        - puts it on the order: AO- orders / drafts through _apply_delivery_collection (same as a manual
--          collection), advance orders through _apply_advance_collection_on_remit (an AdvanceOrderPortalPayments
--          row - the POS Pay In Full takes it in as "Paid on portal", no cash-drawer entry).
--      A collection that can't go on the order is 'Failed' with the reason, and "Try again" on the stop works
--      the same as for a manual one.
--   3. The XenditPayments row is Source 'Delivery' and goes in as ApplyStatus 'Applied' ("Delivery collection")
--      like a POS walk-in, so _apply_xendit_payment never puts it on an order a second time.
--
-- Old Pancake orders (not portal-only) can't use the QR - Pancake doesn't know a XENDIT method. The driver
-- records cash / manual for those as before.
--
-- SWITCH: XenditSettings."DeliveryEnabled" (default OFF, on the Xendit Payments page), separate from the
-- customer and POS switches. Switching to TEST mode turns it off (a test QR can't take real money); turn it
-- back on in test mode only to test it yourself (the driver screen then shows TEST + "Simulate Paid").
--
-- Also: the Edge Function xendit-webhook now records 'RSPS-DLV-' payment requests too (redeploy it), and
-- staff_list_delivery_collections returns the Xendit payment of a collection.
--
-- Run AFTER supabase_xendit_pos_walkin.sql, supabase_xendit_live_mode.sql, supabase_xendit_card_fee.sql,
-- supabase_delivery_driver_collections.sql and supabase_advance_order_portal_payments.sql. Safe to re-run.
-- Needs the Edge Function xendit-delivery-payment (new) + xendit-webhook redeployed, js/delivery.js ?v=xqr1 and
-- js/xenditPayments.js ?v=xdelivery1. Ends with ONE result.

set lock_timeout = '10s';

-- ---------------------------------------------------------------------------
-- 0. Columns

alter table public."XenditSettings" add column if not exists "DeliveryEnabled" boolean not null default false;

alter table public."XenditPayments" add column if not exists "DeliveryStopIDs" uuid[];
alter table public."XenditPayments" add column if not exists "DeliveryDriver" text;

alter table public."DeliveryCollections" add column if not exists "XenditPaymentID" uuid;
create index if not exists "IX_DeliveryCollections_Xendit" on public."DeliveryCollections" ("XenditPaymentID") where "XenditPaymentID" is not null;

-- ---------------------------------------------------------------------------
-- 1. Edge Function only (it checks the staff login first): start a QR for one stop or a combined drop.

drop function if exists public._xendit_delivery_prepare(text, uuid[], numeric, boolean);

create or replace function public._xendit_delivery_prepare(p_username text, p_stop_ids uuid[], p_amount numeric, p_is_test boolean)
returns table(payment_id uuid, external_id text, order_ref text, amount numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_short text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_count int;
  v_collectable numeric := 0;
  v_refs text;
  v_bad text;
begin
  if not coalesce((select s."DeliveryEnabled" from public."XenditSettings" s where s."Id" = 1), false) then
    raise exception 'Xendit QR for deliveries is switched off. A Super User can turn it on in the portal: Xendit Payments > Settings.';
  end if;
  if p_stop_ids is null or cardinality(p_stop_ids) = 0 then
    raise exception 'Pick a stop.';
  end if;
  if v_amount < 1 or v_amount > 50000 then
    raise exception 'A QR Ph payment must be between 1.00 and 50,000.00. Split a bigger amount into more than one QR.';
  end if;

  select count(*), string_agg(coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo"), ' + ' order by ord.n)
    into v_count, v_refs
  from unnest(p_stop_ids) with ordinality as ord(id, n)
  join public."DeliveryStops" s on s."StopID" = ord.id;
  if v_count <> cardinality(p_stop_ids) then
    raise exception 'Stop not found.';
  end if;

  -- Old Pancake orders: no XENDIT method there - collect cash / manual as before.
  select string_agg(s."OrderID", ', ') into v_bad
  from public."DeliveryStops" s
  where s."StopID" = any(p_stop_ids) and s."OrderID" is not null and s."AdvanceTransactionNo" is null
    and not public._is_portal_only_online_order(s."OrderID");
  if v_bad is not null then
    raise exception 'Order % is an old Pancake order - the QR can''t be used for it. Record cash / manual instead.', v_bad;
  end if;

  select coalesce(sum(greatest(coalesce(public._delivery_stop_collectable(u.id), 0), 0)), 0) into v_collectable
  from unnest(p_stop_ids) as u(id);
  if v_amount > v_collectable + 0.005 then
    raise exception 'The amount (%) is more than the balance to collect (%).', v_amount, round(v_collectable, 2);
  end if;

  return query
    insert into public."XenditPayments" as x (
      "ExternalID", "OrderRef", "Purpose", "Amount", "IsTest", "Source",
      "ApplyStatus", "AppliedIn", "AppliedAmount",
      "PosCashier", "DeliveryStopIDs", "DeliveryDriver"
    ) values (
      'RSPS-DLV-' || v_short, left(v_refs, 200), 'Delivery collection', v_amount, coalesce(p_is_test, true), 'Delivery',
      'Applied', 'Delivery collection', v_amount,
      left(p_username, 100), p_stop_ids, left(p_username, 100)
    )
    returning x."PaymentID", x."ExternalID", x."OrderRef", x."Amount";
end;
$$;

revoke all on function public._xendit_delivery_prepare(text, uuid[], numeric, boolean) from public, anon, authenticated;
grant execute on function public._xendit_delivery_prepare(text, uuid[], numeric, boolean) to service_role;

-- Unpaid QRs still open on these stops - the Edge Function cancels them before making a new one, so a
-- customer can never pay two QRs for the same balance.
drop function if exists public._xendit_delivery_open_payments(uuid[]);

create or replace function public._xendit_delivery_open_payments(p_stop_ids uuid[])
returns table(payment_id uuid, invoice_id text, is_test boolean)
language sql
stable
security definer
set search_path = public
as $$
  select x."PaymentID", x."InvoiceID", x."IsTest"
    from public."XenditPayments" x
   where x."Source" = 'Delivery' and x."Status" in ('Pending', 'Creating')
     and x."InvoiceID" is not null and x."DeliveryStopIDs" && p_stop_ids;
$$;

revoke all on function public._xendit_delivery_open_payments(uuid[]) from public, anon, authenticated;
grant execute on function public._xendit_delivery_open_payments(uuid[]) to service_role;

-- A delivery payment's current row (never returns another kind, so a staff login can't read those).
drop function if exists public._xendit_delivery_get_payment(uuid);

create or replace function public._xendit_delivery_get_payment(p_payment_id uuid)
returns table(payment_id uuid, invoice_id text, status text, amount numeric, paid_amount numeric, payment_channel text,
              payment_method text, expires_at timestamptz, is_test boolean, order_ref text, receipt_no text,
              collections_saved int, collections_failed int)
language sql
stable
security definer
set search_path = public
as $$
  select x."PaymentID", x."InvoiceID", x."Status", x."Amount", x."PaidAmount", x."PaymentChannel", x."PaymentMethod",
         x."ExpiresAtUtc", x."IsTest", x."OrderRef", x."ReceiptNo",
         (select count(*)::int from public."DeliveryCollections" dc where dc."XenditPaymentID" = x."PaymentID"),
         (select count(*)::int from public."DeliveryCollections" dc where dc."XenditPaymentID" = x."PaymentID" and dc."ApplyStatus" = 'Failed')
    from public."XenditPayments" x
   where x."PaymentID" = p_payment_id and x."Source" = 'Delivery';
$$;

revoke all on function public._xendit_delivery_get_payment(uuid) from public, anon, authenticated;
grant execute on function public._xendit_delivery_get_payment(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Paid -> the stop's collection(s), on the order. Once per payment; never raises.

create or replace function public._xendit_delivery_complete(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  x public."XenditPayments"%rowtype;
  v_left numeric;
  v_share numeric;
  v_cap numeric;
  v_id uuid;
  v_stop uuid;
  v_n int;
  v_total int;
  v_ref text;
  v_advance text;
  v_ids uuid[] := '{}';
begin
  select * into x from public."XenditPayments" where "PaymentID" = p_payment_id for update;
  if not found or x."Source" <> 'Delivery' or x."Status" <> 'Paid' or x."DeliveryStopIDs" is null then
    return;
  end if;
  if exists (select 1 from public."DeliveryCollections" dc where dc."XenditPaymentID" = x."PaymentID") then
    return;
  end if;

  begin
    v_left := round(coalesce(x."PaidAmount", x."Amount"), 2);
    v_total := cardinality(x."DeliveryStopIDs");
    for v_stop, v_n in select u.id, u.n from unnest(x."DeliveryStopIDs") with ordinality as u(id, n) order by u.n loop
      exit when v_left <= 0.004;
      perform pg_advisory_xact_lock(hashtext('delivery-collection:' || v_stop::text));
      v_cap := greatest(coalesce(public._delivery_stop_collectable(v_stop), 0), 0);
      -- The money is already taken: anything left over goes on the last stop (stop-only part, staff can see it).
      v_share := case when v_n = v_total then v_left else least(v_left, v_cap) end;
      continue when v_share <= 0;
      v_left := round(v_left - v_share, 2);

      select coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo") into v_ref
      from public."DeliveryStops" s where s."StopID" = v_stop;

      v_id := gen_random_uuid();
      insert into public."DeliveryCollections" (
        "CollectionID", "StopID", "OrderRef", "Amount", "MethodCode", "MethodName", "Reference", "CollectedBy",
        "CollectedAtUtc", "RemittedBy", "RemittedAtUtc", "XenditPaymentID"
      ) values (
        v_id, v_stop, v_ref, v_share, 'XENDIT', case when x."IsTest" then 'Xendit TEST' else 'Xendit' end,
        left('QR Ph ' || coalesce(x."ReceiptNo", x."ExternalID") || coalesce(' - ' || nullif(x."PaymentChannel", ''), ''), 200),
        coalesce(x."DeliveryDriver", 'Xendit'), coalesce(x."PaidAtUtc", now()), 'Xendit', now(), x."PaymentID"
      );
      v_ids := v_ids || v_id;
    end loop;

    -- Put each on its order (after all are saved, so the split above saw the stops' balances unchanged).
    foreach v_id in array v_ids loop
      select s."AdvanceTransactionNo" into v_advance
      from public."DeliveryCollections" dc join public."DeliveryStops" s on s."StopID" = dc."StopID"
      where dc."CollectionID" = v_id;
      if v_advance is not null then
        perform public._apply_advance_collection_on_remit(v_id);
      else
        perform public._apply_delivery_collection(v_id);
      end if;
    end loop;

    update public."XenditPayments"
       set "AppliedIn" = 'Delivery collection', "ApplyError" = null, "AppliedAtUtc" = now()
     where "PaymentID" = x."PaymentID";
  exception when others then
    -- ApplyStatus stays 'Applied' so _apply_xendit_payment never touches it; the driver's next status
    -- check (or the Xendit Payments page) shows this and re-runs it.
    update public."XenditPayments"
       set "AppliedIn" = 'Delivery collection NOT saved', "ApplyError" = left(sqlerrm, 500)
     where "PaymentID" = x."PaymentID";
  end;
end;
$$;

revoke all on function public._xendit_delivery_complete(uuid) from public, anon, authenticated;
grant execute on function public._xendit_delivery_complete(uuid) to service_role;

create or replace function public._xendit_delivery_paid_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._xendit_delivery_complete(new."PaymentID");
  return null;
end;
$$;

drop trigger if exists "TR_XenditPayments_DeliveryPaid" on public."XenditPayments";
create trigger "TR_XenditPayments_DeliveryPaid"
  after update of "Status" on public."XenditPayments"
  for each row
  when (new."Source" = 'Delivery' and new."Status" = 'Paid' and old."Status" is distinct from 'Paid')
  execute function public._xendit_delivery_paid_trigger();

-- Xendit Payments page: re-run a "NOT saved" delivery payment.
create or replace function public.admin_retry_xendit_delivery_payment(p_admin_username text, p_admin_password text, p_payment_id uuid)
returns table(applied_in text, apply_error text)
language plpgsql
security definer
set search_path = public
set statement_timeout = '90000'
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  perform public._xendit_delivery_complete(p_payment_id);
  return query select x."AppliedIn", x."ApplyError" from public."XenditPayments" x where x."PaymentID" = p_payment_id;
end;
$$;

grant execute on function public.admin_retry_xendit_delivery_payment(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- 3. Delivery page: collections now say which Xendit payment they came from.
--    (copy of supabase_delivery_driver_collections.sql's version + method_code / xendit_payment_id)

drop function if exists public.staff_list_delivery_collections(text, text, uuid[]);

create or replace function public.staff_list_delivery_collections(p_username text, p_password text, p_stop_ids uuid[])
returns table(
  collection_id uuid, stop_id uuid, order_ref text, amount numeric, applied_amount numeric,
  method_name text, reference text, collected_by text, collected_at_utc timestamptz,
  apply_status text, apply_error text, applied_in text, remitted_by text, remitted_at_utc timestamptz,
  method_code text, xendit_payment_id uuid
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select dc."CollectionID", dc."StopID", dc."OrderRef", dc."Amount", dc."AppliedAmount",
           dc."MethodName", dc."Reference", coalesce(u."DisplayName", dc."CollectedBy")::text, dc."CollectedAtUtc",
           dc."ApplyStatus", dc."ApplyError", dc."AppliedIn",
           coalesce(r."DisplayName", dc."RemittedBy")::text, dc."RemittedAtUtc",
           dc."MethodCode", dc."XenditPaymentID"
    from public."DeliveryCollections" dc
    left join public."StaffUsers" u on u."Username" = dc."CollectedBy"
    left join public."StaffUsers" r on r."Username" = dc."RemittedBy"
    where dc."StopID" = any(p_stop_ids)
    order by dc."CollectedAtUtc";
end;
$$;

grant execute on function public.staff_list_delivery_collections(text, text, uuid[]) to anon;

-- ---------------------------------------------------------------------------
-- 4. Xendit Payments page: the delivery switch, and delivery rows with their driver.

drop function if exists public.admin_get_xendit_settings(text, text);

create or replace function public.admin_get_xendit_settings(p_admin_username text, p_admin_password text)
returns table(enabled boolean, show_on_order_now boolean, updated_by text, updated_at timestamptz, pos_enabled boolean,
              live_mode boolean, card_fee_percent numeric, delivery_enabled boolean)
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
    select s."Enabled", s."ShowOnOrderNow", s."UpdatedBy", s."UpdatedAtUtc", s."PosEnabled", s."LiveMode", s."CardFeePercent",
           s."DeliveryEnabled"
      from public."XenditSettings" s where s."Id" = 1;
end;
$$;

grant execute on function public.admin_get_xendit_settings(text, text) to anon;

create or replace function public.admin_set_xendit_delivery_enabled(p_admin_username text, p_admin_password text, p_delivery_enabled boolean)
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
     set "DeliveryEnabled" = coalesce(p_delivery_enabled, false),
         "UpdatedBy" = p_admin_username,
         "UpdatedAtUtc" = now()
   where "Id" = 1;
end;
$$;

grant execute on function public.admin_set_xendit_delivery_enabled(text, text, boolean) to anon;

-- (copy of supabase_xendit_live_mode.sql's version) switching to TEST turns the delivery switch off too.
create or replace function public.admin_set_xendit_live_mode(p_admin_username text, p_admin_password text, p_live_mode boolean)
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
     set "LiveMode" = coalesce(p_live_mode, false),
         "PosEnabled" = case when coalesce(p_live_mode, false) then "PosEnabled" else false end,
         "DeliveryEnabled" = case when coalesce(p_live_mode, false) then "DeliveryEnabled" else false end,
         "UpdatedBy" = p_admin_username,
         "UpdatedAtUtc" = now()
   where "Id" = 1;
end;
$$;

grant execute on function public.admin_set_xendit_live_mode(text, text, boolean) to anon;

-- (copy of supabase_xendit_card_fee.sql's version + delivery_driver)
drop function if exists public.admin_list_xendit_payments(text, text, text, int);

create or replace function public.admin_list_xendit_payments(p_admin_username text, p_admin_password text,
                                                            p_search text default null, p_limit int default 200)
returns table(payment_id uuid, created_at timestamptz, order_ref text, online_order_id text, purpose text,
              amount numeric, is_test boolean, status text, invoice_url text, expires_at timestamptz,
              create_error text, paid_amount numeric, payment_method text, payment_channel text, paid_at timestamptz,
              apply_status text, apply_error text, applied_in text, applied_amount numeric, external_id text,
              receipt_message_status text, receipt_no text,
              source text, pos_receipt_no text, pos_cashier text, walkin_order_id text, card_fee numeric,
              delivery_driver text)
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
           x."Source", x."PosReceiptNo", x."PosCashier", w."OrderID"::text, x."CardFee",
           coalesce(d."DisplayName", x."DeliveryDriver")::text
      from public."XenditPayments" x
      left join public."OnlineOrders" w
        on x."PosReceiptNo" is not null and w."PosReceiptNo" = x."PosReceiptNo" and w."PosWarehouseId" = x."PosWarehouseId"
      left join public."StaffUsers" d on d."Username" = x."DeliveryDriver"
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
select 'setting' as section, 'Delivery QR switch' as item, case when s."DeliveryEnabled" then 'ON' else 'OFF' end as value
  from public."XenditSettings" s where s."Id" = 1
union all
select 'column', c.table_name || '.' || c.column_name, c.data_type::text
  from information_schema.columns c
 where c.table_schema = 'public'
   and ((c.table_name = 'XenditPayments' and c.column_name in ('DeliveryStopIDs', 'DeliveryDriver'))
     or (c.table_name = 'DeliveryCollections' and c.column_name = 'XenditPaymentID'))
union all
select 'trigger', t.tgname::text, case when t.tgenabled = 'O' then 'enabled' else 'DISABLED' end
  from pg_trigger t where t.tgname = 'TR_XenditPayments_DeliveryPaid'
union all
select 'function', p.proname::text,
       case when has_function_privilege('anon', p.oid, 'EXECUTE') then 'anon'
            when has_function_privilege('service_role', p.oid, 'EXECUTE') then 'service_role only'
            else 'internal' end
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in ('_xendit_delivery_prepare', '_xendit_delivery_open_payments', '_xendit_delivery_get_payment',
                     '_xendit_delivery_complete', 'admin_retry_xendit_delivery_payment', 'admin_set_xendit_delivery_enabled');
