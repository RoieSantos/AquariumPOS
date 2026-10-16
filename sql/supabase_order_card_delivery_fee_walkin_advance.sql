-- Delivery Fee on the Walk-in and Advance order cards - per "in the orders online / advance orders /
-- walk-in orders.. where can we put delivery fee? ... on the order card.. can we add it there?".
--
-- Before: the card's Delivery Fee box only worked on open online orders marked For Delivery. A walk-in
-- (POS -> Pancake as Shipped, usually not For Delivery) and an advance order (no fee at all) could only
-- get a fee on the Delivery calendar, after a stop was made.
--
-- 1. AdvanceOrderProduction."DeliveryFee" - the advance order's fee (portal only; the POS's own
--    AdvanceOrders row is never touched).
-- 2. admin_set_portal_order_delivery_fee re-created (latest: supabase_online_order_shipping_details_sync.sql
--    step 3) - walk-ins (ReceivedAtShop) are now allowed whether or not they're For Delivery and even
--    though their status is Shipped, until they're picked up / delivered / cancelled / returned. Online
--    orders: unchanged. Money to Collect / Balance move with the fee as before (driver collects it).
-- 3. staff_get_advance_order_delivery_fee / staff_set_advance_order_delivery_fee - the advance card's
--    box. Super User or Production Manager (same as the Advance Orders list). Until delivered. Also
--    copies the fee onto the order's stops (ManualDeliveryFee), so the calendar,
--    receipt and amount to collect (Balance + fee) show it right away.
-- 4. Triggers on DeliveryStops: a NEW advance stop starts with the order's fee; a fee typed on the
--    calendar (Edit Details) for an advance stop is copied back to the order, so card and calendar agree.
--
-- Run AFTER supabase_online_order_shipping_details_sync.sql and supabase_delivery_stop_done_post.sql.
-- Do NOT re-run supabase_online_order_shipping_details_sync.sql after this (it would put back the
-- walk-in refusal) - if you must, re-run this file after it. Safe to re-run.
-- Needs js/onlineOrders.js ?v=cardfee2.

set lock_timeout = '10s';

-- 1. -------------------------------------------------------------------------
alter table public."AdvanceOrderProduction" add column if not exists "DeliveryFee" numeric(18, 2);

-- 2. -------------------------------------------------------------------------
drop function if exists public.admin_set_portal_order_delivery_fee(text, text, text, numeric);

create or replace function public.admin_set_portal_order_delivery_fee(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_delivery_fee numeric
)
returns table(delivery_fee numeric, money_to_collect numeric, balance numeric)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
set lock_timeout = '10000'
as $$
declare
  v_order_id text := trim(coalesce(p_order_id, ''));
  v_order public."OnlineOrders"%rowtype;
  v_status text;
  v_old_fee numeric(18, 2);
  v_new_fee numeric(18, 2) := round(coalesce(p_delivery_fee, 0), 2);
  v_delta numeric(18, 2);
  v_walkin boolean;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_new_fee < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;

  begin
    select * into v_order from public."OnlineOrders" where "OrderID" = v_order_id for update;
  exception when lock_not_available then
    raise exception 'Order % is busy (another update is still running on it). Wait a minute, refresh and try again.', v_order_id;
  end;
  if not found then
    raise exception 'Order % not found.', v_order_id;
  end if;

  v_walkin := coalesce(v_order."ReceivedAtShop", false);
  v_status := lower(trim(coalesce(v_order."Status", '')));

  if v_walkin then
    -- Walk-ins are Shipped in Pancake from the start, so their open/closed is the portal's own.
    if v_status in ('cancelled', 'canceled', 'returned', 'returning') then
      raise exception 'Order % is %, its delivery fee can no longer be changed.', v_order_id, v_order."Status";
    end if;
    if v_order."PickedUpAtUtc" is not null then
      raise exception 'Order % was already picked up, its delivery fee can no longer be changed.', v_order_id;
    end if;
    if v_order."DeliveredAtUtc" is not null then
      raise exception 'Order % was already delivered, its delivery fee can no longer be changed.', v_order_id;
    end if;
  else
    if not coalesce(v_order."ForDelivery", false)
       and not exists (select 1 from public."DeliveryStops" s where s."OrderID" = v_order_id) then
      raise exception 'Order % is a pickup order - it has no delivery fee.', v_order_id;
    end if;
    if v_status in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning') then
      raise exception 'Order % is %, its delivery fee can no longer be changed.', v_order_id, v_order."Status";
    end if;
  end if;

  v_old_fee := coalesce(v_order."DeliveryFee", 0);
  v_delta := v_new_fee - v_old_fee;

  update public."OnlineOrders"
  set "DeliveryFee" = nullif(v_new_fee, 0),
      "PortalDeliveryFee" = v_new_fee, -- kept over the next Pancake sync
      "MoneyToCollect" = coalesce("MoneyToCollect", 0) + v_delta,
      "Balance" = coalesce("Balance", 0) + v_delta,
      "Last_Updated_At" = now()
  where "OrderID" = v_order_id;

  update public."AutomatedOrders"
  set "DeliveryFee" = v_new_fee,
      "EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta,
      "UpdatedAtUtc" = now()
  where "PancakeReceiptNo" = v_order_id and "PancakeSyncStatus" = 'Portal';

  -- The calendar follows the order's fee from now on.
  update public."DeliveryStops"
  set "ManualDeliveryFee" = null
  where "OrderID" = v_order_id and "ManualDeliveryFee" is not null;

  return query
    select o."DeliveryFee", o."MoneyToCollect", o."Balance"
    from public."OnlineOrders" o where o."OrderID" = v_order_id;
end;
$$;

grant execute on function public.admin_set_portal_order_delivery_fee(text, text, text, numeric) to anon;

-- 3. -------------------------------------------------------------------------
-- Same people as the Advance Orders list (admin_list_advance_orders).
create or replace function public._advance_order_fee_authorized(p_username text, p_password text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin_authorized(p_username, p_password)
      or (public.is_staff_authorized(p_username, p_password) and public._production_is_manager(p_username));
$$;

revoke execute on function public._advance_order_fee_authorized(text, text) from public, anon, authenticated;

drop function if exists public.staff_get_advance_order_delivery_fee(text, text, text);

create or replace function public.staff_get_advance_order_delivery_fee(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(delivery_fee numeric, delivered boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public._advance_order_fee_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select p."DeliveryFee", p."DeliveredAtUtc" is not null
    from (select trim(coalesce(p_no, '')) as no) x
    left join public."AdvanceOrderProduction" p on p."TransactionNo" = x.no;
end;
$$;

grant execute on function public.staff_get_advance_order_delivery_fee(text, text, text) to anon;

drop function if exists public.staff_set_advance_order_delivery_fee(text, text, text, numeric);

create or replace function public.staff_set_advance_order_delivery_fee(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_delivery_fee numeric
)
returns numeric
language plpgsql
security definer
set search_path = public
set statement_timeout = '30000'
set lock_timeout = '10000'
as $$
declare
  v_no text := trim(coalesce(p_no, ''));
  v_fee numeric(18, 2) := round(coalesce(p_delivery_fee, 0), 2);
begin
  if not public._advance_order_fee_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_fee < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;
  if not exists (select 1 from public."AdvanceOrders" where "TransactionNo" = v_no) then
    raise exception 'Advance order % not found.', v_no;
  end if;

  insert into public."AdvanceOrderProduction" ("TransactionNo") values (v_no) on conflict do nothing;

  if exists (select 1 from public."AdvanceOrderProduction" where "TransactionNo" = v_no and "DeliveredAtUtc" is not null) then
    raise exception 'Advance order % was already delivered, its delivery fee can no longer be changed.', v_no;
  end if;

  update public."AdvanceOrderProduction"
  set "DeliveryFee" = nullif(v_fee, 0),
      "UpdatedAtUtc" = now(),
      "UpdatedBy" = p_admin_username
  where "TransactionNo" = v_no;

  -- Its stops show the new fee (not delivered - checked above; the trigger below copies it back -
  -- same value, no-op).
  update public."DeliveryStops"
  set "ManualDeliveryFee" = nullif(v_fee, 0)
  where "AdvanceTransactionNo" = v_no
    and "ManualDeliveryFee" is distinct from nullif(v_fee, 0);

  return nullif(v_fee, 0);
end;
$$;

grant execute on function public.staff_set_advance_order_delivery_fee(text, text, text, numeric) to anon;

-- 4. -------------------------------------------------------------------------
-- New advance stop -> starts with the order's fee (unless one was typed on it already).
create or replace function public.trg_delivery_stops_advance_fee_in()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new."AdvanceTransactionNo" is not null and new."ManualDeliveryFee" is null then
    select p."DeliveryFee" into new."ManualDeliveryFee"
    from public."AdvanceOrderProduction" p
    where p."TransactionNo" = new."AdvanceTransactionNo";
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_DeliveryStops_AdvanceFeeIn" on public."DeliveryStops";
create trigger "TR_DeliveryStops_AdvanceFeeIn"
  before insert on public."DeliveryStops"
  for each row execute function public.trg_delivery_stops_advance_fee_in();

-- Fee typed on the calendar for an advance stop -> the order's fee too.
create or replace function public.trg_delivery_stops_advance_fee_out()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new."AdvanceTransactionNo" is not null
     and new."ManualDeliveryFee" is distinct from old."ManualDeliveryFee" then
    insert into public."AdvanceOrderProduction" ("TransactionNo") values (new."AdvanceTransactionNo") on conflict do nothing;
    update public."AdvanceOrderProduction"
    set "DeliveryFee" = nullif(new."ManualDeliveryFee", 0),
        "UpdatedAtUtc" = now()
    where "TransactionNo" = new."AdvanceTransactionNo"
      and "DeliveryFee" is distinct from nullif(new."ManualDeliveryFee", 0);
  end if;
  return null;
end;
$$;

drop trigger if exists "TR_DeliveryStops_AdvanceFeeOut" on public."DeliveryStops";
create trigger "TR_DeliveryStops_AdvanceFeeOut"
  after update of "ManualDeliveryFee" on public."DeliveryStops"
  for each row execute function public.trg_delivery_stops_advance_fee_out();

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Verification - one result.
select 'column' as section, 'AdvanceOrderProduction.DeliveryFee' as name,
       exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'AdvanceOrderProduction' and column_name = 'DeliveryFee')::text as ok
union all
select 'function', p.proname, 'true'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('admin_set_portal_order_delivery_fee', 'staff_get_advance_order_delivery_fee', 'staff_set_advance_order_delivery_fee')
union all
select 'walk-in allowed', 'admin_set_portal_order_delivery_fee',
       (pg_get_functiondef('public.admin_set_portal_order_delivery_fee(text, text, text, numeric)'::regprocedure) like '%ReceivedAtShop%')::text
union all
select 'trigger', t.tgname, 'true'
  from pg_trigger t
  where t.tgrelid = 'public."DeliveryStops"'::regclass
    and t.tgname in ('TR_DeliveryStops_AdvanceFeeIn', 'TR_DeliveryStops_AdvanceFeeOut');
