-- Driver collections - per "the driver is receiving money sometimes on the delivery.. how can we fullfill
-- it from the system".
--
-- The driver's stop card already showed "Balance to collect", but there was nowhere to record the money
-- taken at the door, so the order stayed "with balance" and nobody tracked the cash in the driver's hand.
--
-- Flow:
--   1. Driver taps "Record Payment Collected" on the stop (Delivery page, Driver Route View): amount
--      (prefilled with the balance), method (Payment Methods - Cash, GCash, bank...), optional reference.
--      staff_record_delivery_collection saves a DeliveryCollections row and applies it to the order at once:
--        - Pancake online order       -> pos_record_online_order_payment (the POS "Online Pay" logic:
--                                         Pancake's cash / bank_payments, then the portal copy) - so the
--                                         POS, Pancake and portal all see it paid;
--        - portal AO- order           -> AutomatedOrderPayments + Online Orders Amount Paid / Balance
--                                         (shows in the order card's Payments + history);
--        - AO- draft (not confirmed)  -> AutomatedOrderPayments;
--        - Advance order              -> recorded only ('Record only'): the advance balance is the
--                                         POS's - the cashier does Pay In Full in the POS when the
--                                         driver hands the money over.
--      A manual delivery fee typed on the stop (DeliveryStops.ManualDeliveryFee) is not on the order /
--      in Pancake, so anything collected above the order's own balance is kept on the collection as the
--      stop's delivery fee (Amount - AppliedAmount) instead of being pushed onto the order.
--   2. The collection is "With driver" until a Super User marks it Remitted (money handed to the office)
--      on the day's Collections list (admin_remit_delivery_collections).
--   If applying fails (e.g. Pancake down) the collection is still saved - the money IS with the driver -
--   as 'Failed' with the error; "Retry" re-applies it. The collection ID doubles as the POS payment ID,
--   so a retry can never add the payment to Pancake twice.
--
-- Run AFTER supabase_pos_online_pay.sql, supabase_delivery_assign_automated_order_search.sql,
-- supabase_payment_methods_master.sql and supabase_ao_order_payment_history.sql. Safe to re-run.
-- Needs js/delivery.js ?v=collect1 (reload the Delivery page after running).

create table if not exists public."DeliveryCollections" (
  "CollectionID" uuid primary key,           -- made by the page; same ID on a retry
  "StopID" uuid not null references public."DeliveryStops"("StopID") on delete cascade,
  "OrderRef" text,                           -- what the driver saw: order ID / ADV-xxx / AO-xxx
  "Amount" numeric(18, 2) not null,          -- what the driver collected
  "AppliedAmount" numeric(18, 2),            -- the part put on the order (rest = stop-only delivery fee)
  "MethodCode" text not null,                -- PaymentMethods.Code ('CASH' or the Pancake bank ID)
  "MethodName" text not null,
  "Reference" text,
  "CollectedBy" text not null,
  "CollectedAtUtc" timestamptz not null default now(),
  "ApplyStatus" text not null default 'Pending', -- Pending / Applied / Failed / Record only
  "ApplyError" text,
  "AppliedIn" text,
  "AppliedAtUtc" timestamptz,
  "RemittedBy" text,
  "RemittedAtUtc" timestamptz
);

create index if not exists "IX_DeliveryCollections_StopID" on public."DeliveryCollections" ("StopID");
create index if not exists "IX_DeliveryCollections_NotRemitted" on public."DeliveryCollections" ("CollectedAtUtc") where "RemittedAtUtc" is null;

alter table public."DeliveryCollections" enable row level security;
revoke all on public."DeliveryCollections" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Apply one collection to its order. Never raises: the outcome lands on the row.

create or replace function public._apply_delivery_collection(p_collection_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  c public."DeliveryCollections"%rowtype;
  s public."DeliveryStops"%rowtype;
  v_order public."OnlineOrders"%rowtype;
  v_paid numeric;
  v_balance numeric;
  v_apply numeric;
  v_reference text;
  v_result jsonb;
  v_tender jsonb;
begin
  select * into c from public."DeliveryCollections" where "CollectionID" = p_collection_id for update;
  if not found or c."ApplyStatus" in ('Applied', 'Record only') then
    return;
  end if;
  select * into s from public."DeliveryStops" where "StopID" = c."StopID";

  v_reference := left('Delivery - collected by ' || c."CollectedBy" || coalesce(' - ' || nullif(trim(c."Reference"), ''), ''), 200);

  begin
    -- Advance order: the balance lives in the POS - record only.
    if s."AdvanceTransactionNo" is not null then
      update public."DeliveryCollections"
      set "ApplyStatus" = 'Record only', "AppliedAmount" = 0, "ApplyError" = null,
          "AppliedIn" = 'Advance order - Pay In Full in the POS when remitted', "AppliedAtUtc" = now()
      where "CollectionID" = c."CollectionID";
      return;
    end if;

    -- AO- draft (not confirmed yet): straight onto its payments.
    if s."OrderID" is null and s."AutomatedOrderNo" is not null then
      v_paid := coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = s."AutomatedOrderNo"), 0);
      v_apply := least(c."Amount", greatest(coalesce(public._automated_order_total(s."AutomatedOrderNo"), 0) - v_paid, 0));
      if v_apply > 0 then
        insert into public."AutomatedOrderPayments" ("OrderNo", "Amount", "Method", "Reference", "RecordedBy")
        values (s."AutomatedOrderNo", v_apply, left(c."MethodName", 30), v_reference, left(c."CollectedBy", 100));
      end if;
      update public."DeliveryCollections"
      set "ApplyStatus" = 'Applied', "AppliedAmount" = v_apply, "ApplyError" = null,
          "AppliedIn" = 'Automated order (draft)', "AppliedAtUtc" = now()
      where "CollectionID" = c."CollectionID";
      return;
    end if;

    select * into v_order from public."OnlineOrders" where "OrderID" = s."OrderID";
    if not found then
      raise exception 'Order % is not on the portal.', s."OrderID";
    end if;
    if lower(trim(coalesce(v_order."Status", ''))) in ('canceled', 'cancelled', 'cancel') then
      raise exception 'Order % is Cancelled.', s."OrderID";
    end if;

    -- Portal-only AO- order: AutomatedOrderPayments + Amount Paid / Balance.
    if public._is_portal_only_online_order(s."OrderID") then
      if not exists (select 1 from public."AutomatedOrders" where "OrderNo" = s."OrderID") then
        raise exception 'Order % has no Automated Order record to add the payment to.', s."OrderID";
      end if;
      v_paid := coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = s."OrderID"), 0);
      v_apply := least(c."Amount", greatest(coalesce(v_order."MoneyToCollect", 0) - v_paid, 0));
      if v_apply > 0 then
        insert into public."AutomatedOrderPayments" ("OrderNo", "Amount", "Method", "Reference", "RecordedBy")
        values (s."OrderID", v_apply, left(c."MethodName", 30), v_reference, left(c."CollectedBy", 100));
        update public."OnlineOrders" o
        set "AmountPaid" = v_paid + v_apply,
            "Balance" = coalesce(o."MoneyToCollect", 0) - (v_paid + v_apply),
            "LastPaid_Date" = (now() at time zone 'Asia/Manila')::date,
            "LastPaid_Time" = to_char(now() at time zone 'Asia/Manila', 'HH24:MI:SS')
        where o."OrderID" = s."OrderID";
      end if;
      update public."DeliveryCollections"
      set "ApplyStatus" = 'Applied', "AppliedAmount" = v_apply, "ApplyError" = null,
          "AppliedIn" = 'Portal (AO order)', "AppliedAtUtc" = now()
      where "CollectionID" = c."CollectionID";
      return;
    end if;

    -- Pancake order: the POS Online Pay logic, with this collection's ID as its payment ID.
    v_apply := least(c."Amount", greatest(coalesce(v_order."Balance", 0), 0));
    if v_apply <= 0 then
      update public."DeliveryCollections"
      set "ApplyStatus" = 'Applied', "AppliedAmount" = 0, "ApplyError" = null,
          "AppliedIn" = 'Nothing owed on the order', "AppliedAtUtc" = now()
      where "CollectionID" = c."CollectionID";
      return;
    end if;
    v_tender := case when c."MethodCode" = 'CASH'
      then jsonb_build_object('tender_code', 'CASH', 'tender_name', 'Cash', 'bank_key', null, 'amount', v_apply)
      else jsonb_build_object('tender_code', left(c."MethodName", 30), 'tender_name', c."MethodName", 'bank_key', c."MethodCode", 'amount', v_apply)
    end;
    v_result := public.pos_record_online_order_payment(
      (select decrypted_secret from vault.decrypted_secrets where name = 'POS_API_KEY' limit 1),
      c."CollectionID", s."OrderID", jsonb_build_array(v_tender),
      left('Driver: ' || c."CollectedBy", 100), 'Delivery', 'DLV-' || left(c."CollectionID"::text, 8));
    -- ok=false comes back WITHOUT raising, and must not raise here either: its OnlineOrderStorePayments
    -- row (Pancake state before / target) has to survive, it's what keeps a retry from paying twice.
    if not coalesce((v_result ->> 'ok')::boolean, false) then
      update public."DeliveryCollections"
      set "ApplyStatus" = 'Failed', "AppliedAmount" = 0,
          "ApplyError" = left(coalesce(v_result ->> 'error', 'The payment was not recorded.'), 500)
      where "CollectionID" = c."CollectionID";
      return;
    end if;
    update public."DeliveryCollections"
    set "ApplyStatus" = 'Applied', "AppliedAmount" = coalesce((v_result ->> 'amount')::numeric, v_apply), "ApplyError" = null,
        "AppliedIn" = coalesce((select sp."RecordedIn" from public."OnlineOrderStorePayments" sp where sp."PaymentID" = c."CollectionID"), 'Pancake'),
        "AppliedAtUtc" = now()
    where "CollectionID" = c."CollectionID";
  exception when others then
    update public."DeliveryCollections"
    set "ApplyStatus" = 'Failed', "AppliedAmount" = 0, "ApplyError" = left(sqlerrm, 500)
    where "CollectionID" = c."CollectionID";
  end;
end;
$$;

revoke all on function public._apply_delivery_collection(uuid) from public, anon, authenticated;

-- What the driver can still record on a stop: its balance to collect (same formula as
-- admin_list_delivery_stops) minus collections not reflected in that balance yet (Failed / Record only,
-- and the stop-only delivery-fee part of applied ones).
create or replace function public._delivery_stop_collectable(p_stop_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select
    coalesce(o."Balance", a."Balance",
             public._automated_order_total(ao."OrderNo")
               - coalesce((select sum(p."Amount") from public."AutomatedOrderPayments" p where p."OrderNo" = ao."OrderNo"), 0))
      + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0)
      - coalesce((select sum(dc."Amount" - coalesce(dc."AppliedAmount", 0))
                  from public."DeliveryCollections" dc where dc."StopID" = s."StopID"), 0)
  from public."DeliveryStops" s
  left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
  left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
  left join public."AutomatedOrders" ao on ao."OrderNo" = s."AutomatedOrderNo"
  where s."StopID" = p_stop_id;
$$;

revoke all on function public._delivery_stop_collectable(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Payment methods the driver can pick (active, named; Cash first).

drop function if exists public.staff_list_delivery_payment_methods(text, text);

create or replace function public.staff_list_delivery_payment_methods(p_username text, p_password text)
returns table(code text, name text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select pm."Code", coalesce(nullif(trim(pm."Name"), ''), nullif(trim(pm."PancakeName"), ''))::text
    from public."PaymentMethods" pm
    where pm."IsActive" and (pm."Code" = 'CASH' or coalesce(nullif(trim(pm."Name"), ''), nullif(trim(pm."PancakeName"), '')) is not null)
    order by (pm."Code" = 'CASH') desc, 2;
end;
$$;

grant execute on function public.staff_list_delivery_payment_methods(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 3. Record a collection (driver). Same p_collection_id again = retry, never a second collection.

drop function if exists public.staff_record_delivery_collection(text, text, uuid, uuid, numeric, text, text);

create or replace function public.staff_record_delivery_collection(
  p_username text,
  p_password text,
  p_collection_id uuid,
  p_stop_id uuid,
  p_amount numeric,
  p_method_code text,
  p_reference text
)
returns table(apply_status text, apply_error text, applied_amount numeric, applied_in text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '120000'
as $$
declare
  v_existing public."DeliveryCollections"%rowtype;
  v_method_name text;
  v_collectable numeric;
  v_order_ref text;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  if p_collection_id is null or p_stop_id is null then
    raise exception 'Collection ID and stop are required.';
  end if;

  perform pg_advisory_xact_lock(hashtext('delivery-collection:' || p_stop_id::text));

  select * into v_existing from public."DeliveryCollections" where "CollectionID" = p_collection_id;
  if found then
    if v_existing."StopID" <> p_stop_id then
      raise exception 'This collection belongs to another stop.';
    end if;
  else
    if v_amount <= 0 then
      raise exception 'Enter the amount collected.';
    end if;
    select coalesce(nullif(trim(pm."Name"), ''), nullif(trim(pm."PancakeName"), ''), 'Cash') into v_method_name
    from public."PaymentMethods" pm where pm."Code" = p_method_code and pm."IsActive";
    if v_method_name is null then
      raise exception 'Pick a payment method.';
    end if;

    select coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo") into v_order_ref
    from public."DeliveryStops" s where s."StopID" = p_stop_id;
    if not found then
      raise exception 'Stop not found.';
    end if;

    v_collectable := coalesce(public._delivery_stop_collectable(p_stop_id), 0);
    if v_amount > v_collectable + 0.005 then
      raise exception 'The amount (%) is more than the balance to collect (%).', v_amount, round(greatest(v_collectable, 0), 2);
    end if;

    insert into public."DeliveryCollections" ("CollectionID", "StopID", "OrderRef", "Amount", "MethodCode", "MethodName", "Reference", "CollectedBy")
    values (p_collection_id, p_stop_id, v_order_ref, v_amount, p_method_code, v_method_name,
            nullif(left(trim(coalesce(p_reference, '')), 200), ''), p_username);
  end if;

  perform public._apply_delivery_collection(p_collection_id);

  return query
    select dc."ApplyStatus", dc."ApplyError", dc."AppliedAmount", dc."AppliedIn"
    from public."DeliveryCollections" dc where dc."CollectionID" = p_collection_id;
end;
$$;

grant execute on function public.staff_record_delivery_collection(text, text, uuid, uuid, numeric, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. Retry a Failed collection (anyone on the Delivery page).

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
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;
  select "StopID" into v_stop from public."DeliveryCollections" where "CollectionID" = p_collection_id;
  if v_stop is null then
    raise exception 'Collection not found.';
  end if;
  perform pg_advisory_xact_lock(hashtext('delivery-collection:' || v_stop::text));
  perform public._apply_delivery_collection(p_collection_id);
  return query
    select dc."ApplyStatus", dc."ApplyError", dc."AppliedAmount", dc."AppliedIn"
    from public."DeliveryCollections" dc where dc."CollectionID" = p_collection_id;
end;
$$;

grant execute on function public.staff_retry_delivery_collection(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- 5. Mark collections Remitted - the driver handed the money to the office. Super Users only.

drop function if exists public.admin_remit_delivery_collections(text, text, uuid[]);

create or replace function public.admin_remit_delivery_collections(p_admin_username text, p_admin_password text, p_collection_ids uuid[])
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_count int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User can mark collections remitted.';
  end if;
  update public."DeliveryCollections"
  set "RemittedBy" = p_admin_username, "RemittedAtUtc" = now()
  where "CollectionID" = any(p_collection_ids) and "RemittedAtUtc" is null;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.admin_remit_delivery_collections(text, text, uuid[]) to anon;

-- ---------------------------------------------------------------------------
-- 6. Collections for a set of stops (driver cards + the day's Collections list).

drop function if exists public.staff_list_delivery_collections(text, text, uuid[]);

create or replace function public.staff_list_delivery_collections(p_username text, p_password text, p_stop_ids uuid[])
returns table(
  collection_id uuid, stop_id uuid, order_ref text, amount numeric, applied_amount numeric,
  method_name text, reference text, collected_by text, collected_at_utc timestamptz,
  apply_status text, apply_error text, applied_in text, remitted_by text, remitted_at_utc timestamptz
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
           coalesce(r."DisplayName", dc."RemittedBy")::text, dc."RemittedAtUtc"
    from public."DeliveryCollections" dc
    left join public."StaffUsers" u on u."Username" = dc."CollectedBy"
    left join public."StaffUsers" r on r."Username" = dc."RemittedBy"
    where dc."StopID" = any(p_stop_ids)
    order by dc."CollectedAtUtc";
end;
$$;

grant execute on function public.staff_list_delivery_collections(text, text, uuid[]) to anon;

notify pgrst, 'reload schema';
