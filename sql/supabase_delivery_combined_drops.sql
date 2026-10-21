-- Delivery: combined drops - per "if an customer has multiple orders and plan to deliver it on one day..
-- how are we going to treat it on the calendar" / "there will be an option if the customer will be
-- charge once or per order" / "Production manager / store manager and sales users" can change it.
--
-- A DROP = the stops on one date with the same customer + the same address (both compared loosely:
-- lower case, letters/digits only). Each order is still its own DeliveryStops row - fees, balances,
-- payments, receipts and Delivered stay per order. The calendar / driver view group them on screen.
--
-- FEE MODE per drop (DeliveryDropFeeModes, keyed by date + drop key; no row = 'once'):
--   once      (default) - ONE fee for the trip: the "carrier" order keeps its fee, every other order in
--             the drop gets 0, remembered in DeliveryStops."CombinedFeeWaived" so it can be put back.
--   per_order - every order charges its own fee (as before).
-- The fee is written to the REAL fee (not just the screen), the same way Edit Details / the order card
-- do it, so balances, the driver's amount to collect and payments all agree:
--   online order, editable  -> the order's portal fee (OnlineOrders DeliveryFee / PortalDeliveryFee /
--                              MoneyToCollect / Balance - same as admin_set_portal_order_delivery_fee)
--   online order, closed (Shipped etc.) or already has a stop fee -> the stop's ManualDeliveryFee
--   advance order           -> the stop's ManualDeliveryFee (copied to the order by TR_DeliveryStops_AdvanceFeeOut)
--   AO draft (not confirmed) -> left alone (it becomes an online order on Confirm, and is grouped then)
--
-- CARRIER = the order that keeps the fee: one already Done first, then one whose fee is already paid,
-- then the biggest fee, then the first booked. If the carrier leaves the drop (moved to another day,
-- removed, cancelled, or its address / customer changed) the drop is worked out again and the fee
-- moves to a remaining order. Rebalancing runs by itself from triggers on DeliveryStops (add / move /
-- remove / address / fee changes) and OnlineOrders (status, fee, customer, address changes).
-- Never touched: stops already Done / Delivered, cancelled / returned orders. An order whose fee is
-- already PAID is not set to 0 (that would leave a credit) - it stays charged and is flagged
-- (fee_combined_with set, fee > 0) so staff can sort out a refund or switch the drop to Per order.
--
-- Re-creates admin_list_delivery_stops (latest: supabase_delivery_assign_automated_order_search.sql)
-- with 4 new trailing columns: drop_key, drop_fee_mode, fee_combined_with, combined_fee_waived.
-- New: staff_set_delivery_drop_fee_mode (Super User / Production Manager / Store Manager / Sales User).
--
-- Run AFTER supabase_delivery_assign_automated_order_search.sql, supabase_order_card_delivery_fee_walkin_advance.sql
-- and supabase_delivery_stop_done_post.sql. Safe to re-run. Needs js/delivery.js ?v=drops1.
-- Ends with one check result.

set lock_timeout = '10s';

alter table public."DeliveryStops" add column if not exists "CombinedFeeWaived" numeric(18, 2);
alter table public."DeliveryStops" add column if not exists "CombinedFeeWaivedOn" varchar(10);
alter table public."DeliveryStops" add column if not exists "FeeCombinedWithStopID" uuid;

reset lock_timeout;

alter table public."DeliveryStops" drop constraint if exists "FK_DeliveryStops_FeeCombinedWith";
alter table public."DeliveryStops" add constraint "FK_DeliveryStops_FeeCombinedWith"
  foreign key ("FeeCombinedWithStopID") references public."DeliveryStops"("StopID") on delete set null;

comment on column public."DeliveryStops"."CombinedFeeWaived" is 'Delivery fee taken off this order because its drop (same customer + address + date) is charged once - put back if the order leaves the drop or the drop is switched to Per order. See supabase_delivery_combined_drops.sql.';
comment on column public."DeliveryStops"."CombinedFeeWaivedOn" is '''order'' = waived on the order''s portal fee, ''stop'' = on this stop''s ManualDeliveryFee.';
comment on column public."DeliveryStops"."FeeCombinedWithStopID" is 'The stop in the same drop that carries the one delivery fee (null = this stop charges its own fee).';

create table if not exists public."DeliveryDropFeeModes" (
  "DeliveryDate" date not null,
  "DropKey" text not null,
  "FeeMode" varchar(10) not null check ("FeeMode" in ('once', 'per_order')),
  "ChangedBy" varchar(100),
  "ChangedAtUtc" timestamptz not null default now(),
  primary key ("DeliveryDate", "DropKey")
);

alter table public."DeliveryDropFeeModes" enable row level security;
revoke all on public."DeliveryDropFeeModes" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Drop key: customer + address, loosely compared. Null = never grouped (no real customer or address -
--    e.g. Pancake's "POS WALKIN ORDERS" / "Walkin" placeholders with nothing typed over them).

create or replace function public._delivery_drop_key(p_name text, p_address text, p_geocoded text)
returns text
language sql
immutable
as $$
  select case when x.n is null or x.n = 'poswalkinorders' or x.ad is null then null else x.n || '|' || x.ad end
  from (
    select nullif(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '', 'g'), '') as n,
           nullif(regexp_replace(lower(
             case when lower(trim(coalesce(p_address, ''))) in ('', 'walkin') then coalesce(p_geocoded, '') else p_address end
           ), '[^a-z0-9]+', '', 'g'), '') as ad
  ) x;
$$;

-- Every stop on a date, with what the rebalance needs.
create or replace function public._delivery_drop_members(p_date date)
returns table(
  stop_id uuid,
  drop_key text,
  kind text,
  order_id text,
  created_at timestamptz,
  manual_fee numeric,
  order_fee numeric,
  current_fee numeric,
  waived numeric,
  waived_on text,
  combined_with uuid,
  balance numeric,
  is_done boolean,
  is_closed boolean,
  order_editable boolean
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select s."StopID",
         public._delivery_drop_key(
           coalesce(nullif(trim(s."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''),
                    o."CustomerName", a."CustomerName", ao."CustomerName"),
           coalesce(nullif(trim(s."ManualAddress"), ''), o."ShippingAddress", ao."DeliveryAddress"),
           s."GeocodedAddress"),
         case when s."AdvanceTransactionNo" is not null then 'advance'
              when s."AutomatedOrderNo" is not null then 'automated'
              else 'online' end,
         s."OrderID"::text,
         s."CreatedAtUtc",
         s."ManualDeliveryFee",
         o."DeliveryFee",
         case when s."AdvanceTransactionNo" is not null then coalesce(s."ManualDeliveryFee", 0)
              else coalesce(s."ManualDeliveryFee", o."DeliveryFee", 0) end,
         s."CombinedFeeWaived",
         s."CombinedFeeWaivedOn"::text,
         s."FeeCombinedWithStopID",
         -- Same balance the stops list shows.
         coalesce(o."Balance", a."Balance") + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
         exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID")
           or o."DeliveredAtUtc" is not null or p."DeliveredAtUtc" is not null,
         lower(trim(coalesce(o."Status", ''))) in ('cancelled', 'canceled', 'cancel', 'returned', 'returning'),
         -- Same rule as admin_set_portal_order_delivery_fee.
         case when o."OrderID" is null then false
              when coalesce(o."ReceivedAtShop", false)
                then lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled', 'returned', 'returning')
                     and o."PickedUpAtUtc" is null and o."DeliveredAtUtc" is null
              else lower(trim(coalesce(o."Status", ''))) not in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning')
         end
  from public."DeliveryStops" s
  left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
  left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
  left join public."AdvanceOrderProduction" p on p."TransactionNo" = s."AdvanceTransactionNo"
  left join public."AutomatedOrders" ao on ao."OrderNo" = s."AutomatedOrderNo"
  where s."DeliveryDate" = p_date;
$$;

revoke all on function public._delivery_drop_members(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Write an order's portal fee (the body of admin_set_portal_order_delivery_fee, no auth / status
--    checks - callers check editability first).

create or replace function public._delivery_set_order_fee(p_order_id text, p_fee numeric)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_fee numeric(18, 2) := round(coalesce(p_fee, 0), 2);
  v_delta numeric(18, 2);
begin
  select v_fee - coalesce(o."DeliveryFee", 0) into v_delta from public."OnlineOrders" o where o."OrderID" = p_order_id;
  if v_delta is null then
    return;
  end if;

  update public."OnlineOrders"
  set "DeliveryFee" = nullif(v_fee, 0),
      "PortalDeliveryFee" = v_fee,
      "MoneyToCollect" = coalesce("MoneyToCollect", 0) + v_delta,
      "Balance" = coalesce("Balance", 0) + v_delta,
      "Last_Updated_At" = now()
  where "OrderID" = p_order_id
    and ("PortalDeliveryFee" is distinct from v_fee or v_delta <> 0);

  if v_delta <> 0 then
    update public."AutomatedOrders"
    set "DeliveryFee" = v_fee,
        "EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta,
        "UpdatedAtUtc" = now()
    where "PancakeReceiptNo" = p_order_id and "PancakeSyncStatus" = 'Portal';
  end if;
end;
$$;

revoke all on function public._delivery_set_order_fee(text, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Rebalance every drop on a date. Idempotent - running it twice changes nothing the second time.

create or replace function public._delivery_rebalance_date(p_date date)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r record;
  m record;
  v_mode text;
  v_carrier uuid;
  v_level text;
  v_combined uuid;
begin
  if p_date is null then
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext('delivery-drop:' || p_date::text));
  -- The triggers below skip while this is on, so our own fee writes don't start another rebalance.
  perform set_config('rspet.delivery_drop_rebalance', 'on', true);

  for r in
    select x.drop_key,
           count(*) filter (where x.kind in ('online', 'advance') and not x.is_closed) as n_active
    from public._delivery_drop_members(p_date) x
    group by x.drop_key
  loop
    v_mode := case when r.drop_key is null then 'per_order'
                   else coalesce((select f."FeeMode" from public."DeliveryDropFeeModes" f
                                   where f."DeliveryDate" = p_date and f."DropKey" = r.drop_key), 'once') end;
    v_carrier := null;

    if v_mode = 'once' and r.n_active >= 2 then
      select x.stop_id into v_carrier
      from public._delivery_drop_members(p_date) x
      where x.drop_key = r.drop_key and x.kind in ('online', 'advance') and not x.is_closed
        and coalesce(x.waived, x.current_fee) > 0
      order by x.is_done desc,
               (x.waived is null and x.current_fee > 0 and x.balance < x.current_fee - 0.005) desc, -- fee already paid
               coalesce(x.waived, x.current_fee) desc,
               x.created_at, x.stop_id
      limit 1;
    end if;

    for m in
      select x.* from public._delivery_drop_members(p_date) x
      where x.drop_key is not distinct from r.drop_key
        and x.kind in ('online', 'advance') and not x.is_done
    loop
      v_combined := case when m.is_closed or v_carrier is null or m.stop_id = v_carrier then null else v_carrier end;

      if v_combined is null then
        -- Charges its own fee: put back a waived one (unless staff already typed a new fee on it).
        if m.waived is not null and not m.is_closed and m.current_fee > 0 then
          update public."DeliveryStops" set "CombinedFeeWaived" = null, "CombinedFeeWaivedOn" = null where "StopID" = m.stop_id;
        elsif m.waived is not null and not m.is_closed then
          if m.waived_on = 'order' and m.order_editable and m.manual_fee is null then
            perform public._delivery_set_order_fee(m.order_id, m.waived);
          else
            update public."DeliveryStops"
            set "ManualDeliveryFee" = case when m.kind = 'online' and coalesce(m.order_fee, 0) = m.waived then null else m.waived end
            where "StopID" = m.stop_id;
          end if;
          update public."DeliveryStops" set "CombinedFeeWaived" = null, "CombinedFeeWaivedOn" = null where "StopID" = m.stop_id;
        end if;
      elsif m.current_fee > 0 and m.balance - m.current_fee >= -0.005 then
        -- Rides on the carrier's fee: take its own off (not when that fee is already paid - see top).
        v_level := case when m.kind = 'online' and m.manual_fee is null and m.order_editable then 'order' else 'stop' end;
        if v_level = 'order' then
          perform public._delivery_set_order_fee(m.order_id, 0);
        else
          update public."DeliveryStops" set "ManualDeliveryFee" = 0 where "StopID" = m.stop_id;
        end if;
        update public."DeliveryStops"
        set "CombinedFeeWaived" = m.current_fee, "CombinedFeeWaivedOn" = v_level
        where "StopID" = m.stop_id;
      end if;

      if m.combined_with is distinct from v_combined then
        update public."DeliveryStops" set "FeeCombinedWithStopID" = v_combined where "StopID" = m.stop_id;
      end if;
    end loop;
  end loop;

  perform set_config('rspet.delivery_drop_rebalance', 'off', true);
end;
$$;

revoke all on function public._delivery_rebalance_date(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Triggers. A failed rebalance never blocks the change that set it off (logged as a warning).

create or replace function public._delivery_stops_rebalance_drops()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(current_setting('rspet.delivery_drop_rebalance', true), 'off') = 'on' then
    return null;
  end if;
  begin
    if TG_OP = 'DELETE' then
      -- A removed stop takes its order out of the drop: give the order its fee back.
      if OLD."CombinedFeeWaived" is not null and OLD."CombinedFeeWaivedOn" = 'order' and OLD."OrderID" is not null then
        perform set_config('rspet.delivery_drop_rebalance', 'on', true);
        perform public._delivery_set_order_fee(OLD."OrderID", OLD."CombinedFeeWaived")
        from public."OnlineOrders" o
        where o."OrderID" = OLD."OrderID" and coalesce(o."DeliveryFee", 0) = 0
          and o."DeliveredAtUtc" is null
          and lower(trim(coalesce(o."Status", ''))) not in ('cancelled', 'canceled', 'returned', 'returning');
        perform set_config('rspet.delivery_drop_rebalance', 'off', true);
      end if;
      perform public._delivery_rebalance_date(OLD."DeliveryDate");
    else
      perform public._delivery_rebalance_date(NEW."DeliveryDate");
      if TG_OP = 'UPDATE' and OLD."DeliveryDate" is distinct from NEW."DeliveryDate" then
        perform public._delivery_rebalance_date(OLD."DeliveryDate");
      end if;
    end if;
  exception when others then
    perform set_config('rspet.delivery_drop_rebalance', 'off', true);
    raise warning 'Delivery drop fee rebalance failed: %', sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists "TR_DeliveryStops_RebalanceDrops_InsDel" on public."DeliveryStops";
create trigger "TR_DeliveryStops_RebalanceDrops_InsDel"
  after insert or delete on public."DeliveryStops"
  for each row execute function public._delivery_stops_rebalance_drops();

drop trigger if exists "TR_DeliveryStops_RebalanceDrops_Upd" on public."DeliveryStops";
create trigger "TR_DeliveryStops_RebalanceDrops_Upd"
  after update of "DeliveryDate", "OrderID", "AdvanceTransactionNo", "AutomatedOrderNo", "ManualAddress",
                  "ManualCustomerName", "GeocodedAddress", "ManualDeliveryFee" on public."DeliveryStops"
  for each row
  when (OLD."DeliveryDate" is distinct from NEW."DeliveryDate"
     or OLD."OrderID" is distinct from NEW."OrderID"
     or OLD."AdvanceTransactionNo" is distinct from NEW."AdvanceTransactionNo"
     or OLD."AutomatedOrderNo" is distinct from NEW."AutomatedOrderNo"
     or OLD."ManualAddress" is distinct from NEW."ManualAddress"
     or OLD."ManualCustomerName" is distinct from NEW."ManualCustomerName"
     or OLD."GeocodedAddress" is distinct from NEW."GeocodedAddress"
     or OLD."ManualDeliveryFee" is distinct from NEW."ManualDeliveryFee")
  execute function public._delivery_stops_rebalance_drops();

-- Order side: cancelled / un-cancelled, a fee typed on the order card, or customer / address changed.
create or replace function public._online_orders_rebalance_drops()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_date date;
begin
  if coalesce(current_setting('rspet.delivery_drop_rebalance', true), 'off') = 'on' then
    return null;
  end if;
  begin
    for v_date in
      select distinct s."DeliveryDate" from public."DeliveryStops" s
      where s."OrderID" = NEW."OrderID"
        and s."DeliveryDate" >= (now() at time zone 'Asia/Manila')::date - 7
    loop
      perform public._delivery_rebalance_date(v_date);
    end loop;
  exception when others then
    perform set_config('rspet.delivery_drop_rebalance', 'off', true);
    raise warning 'Delivery drop fee rebalance failed for order %: %', NEW."OrderID", sqlerrm;
  end;
  return null;
end;
$$;

drop trigger if exists "TR_OnlineOrders_RebalanceDrops" on public."OnlineOrders";
create trigger "TR_OnlineOrders_RebalanceDrops"
  after update of "Status", "PortalDeliveryFee", "CustomerName", "WalkinCustomerName", "ShippingAddress" on public."OnlineOrders"
  for each row
  when (OLD."Status" is distinct from NEW."Status"
     or OLD."PortalDeliveryFee" is distinct from NEW."PortalDeliveryFee"
     or OLD."CustomerName" is distinct from NEW."CustomerName"
     or OLD."WalkinCustomerName" is distinct from NEW."WalkinCustomerName"
     or OLD."ShippingAddress" is distinct from NEW."ShippingAddress")
  execute function public._online_orders_rebalance_drops();

-- ---------------------------------------------------------------------------
-- 5. Charge once / per order - Super User, Production Manager, Store Manager, Sales User.

drop function if exists public.staff_set_delivery_drop_fee_mode(text, text, date, text, text);

create or replace function public.staff_set_delivery_drop_fee_mode(
  p_username text,
  p_password text,
  p_delivery_date date,
  p_drop_key text,
  p_fee_mode text
)
returns table(stop_id uuid, delivery_fee numeric, fee_combined_with uuid, combined_fee_waived numeric)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_mode text := lower(trim(coalesce(p_fee_mode, '')));
begin
  if not public.is_staff_authorized(p_username, p_password)
     or not exists (
       select 1 from public."StaffUsers" u
       where u."Username" = p_username and u."IsActive"
         and (u."SuperUser" or coalesce(u."StoreManager", false) or coalesce(u."SalesUser", false)
              or 'ProductionManager' = any(coalesce(u."StaffRoles", '{}')))
     ) then
    raise exception 'Only a Super User, Production Manager, Store Manager or Sales User can change how a combined delivery is charged.';
  end if;
  if v_mode not in ('once', 'per_order') then
    raise exception 'Pick Charge once or Charge per order.';
  end if;
  if p_delivery_date is null or nullif(trim(coalesce(p_drop_key, '')), '') is null then
    raise exception 'Delivery date and drop are required.';
  end if;
  if (select count(*) from public._delivery_drop_members(p_delivery_date) x where x.drop_key = p_drop_key) < 2 then
    raise exception 'That customer has only one order on this date - nothing to combine. Refresh the page.';
  end if;

  insert into public."DeliveryDropFeeModes" ("DeliveryDate", "DropKey", "FeeMode", "ChangedBy", "ChangedAtUtc")
  values (p_delivery_date, p_drop_key, v_mode, p_username, now())
  on conflict ("DeliveryDate", "DropKey") do update
    set "FeeMode" = excluded."FeeMode", "ChangedBy" = excluded."ChangedBy", "ChangedAtUtc" = excluded."ChangedAtUtc";

  perform public._delivery_rebalance_date(p_delivery_date);

  return query
    select x.stop_id, x.current_fee, x.combined_with, x.waived
    from public._delivery_drop_members(p_delivery_date) x
    where x.drop_key = p_drop_key;
end;
$$;

grant execute on function public.staff_set_delivery_drop_fee_mode(text, text, date, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 6. Stops list: + drop_key, drop_fee_mode, fee_combined_with (the carrier's order ref),
--    combined_fee_waived. Otherwise unchanged from supabase_delivery_assign_automated_order_search.sql.

drop function if exists public.admin_list_delivery_stops(text, text, date, date);

create or replace function public.admin_list_delivery_stops(p_admin_username text, p_admin_password text, p_start_date date, p_end_date date)
returns table(
  stop_id uuid,
  delivery_date date,
  truck_id uuid,
  truck_name text,
  stop_sequence int,
  order_id text,
  customer_name text,
  status text,
  shipping_address text,
  money_to_collect numeric,
  balance numeric,
  notes text,
  latitude numeric,
  longitude numeric,
  geocode_status text,
  geocoded_address text,
  route_name text,
  created_by text,
  note_print text,
  contact_number text,
  is_manual_address boolean,
  source text,
  delivery_fee numeric,
  is_manual_delivery_fee boolean,
  drop_key text,              -- this file
  drop_fee_mode text,         -- this file: 'once' / 'per_order'
  fee_combined_with text,     -- this file: order ref of the stop carrying the drop's one fee
  combined_fee_waived numeric -- this file: the fee taken off this order (null = none)
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s."StopID", s."DeliveryDate", s."TruckID", t."TruckName"::text, s."StopSequence",
           coalesce(o."OrderID", 'ADV-' || a."TransactionNo", ao."OrderNo")::text,
           coalesce(nullif(trim(s."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''),
                    o."CustomerName", a."CustomerName", ao."CustomerName")::text,
           case when a."TransactionNo" is not null
                  then 'Advance' || coalesce(' - ' || public._advance_order_prod_status(p), '')
                when ao."OrderNo" is not null
                  then ao."Status" || public._automated_order_pending_label(ao."PancakeSyncStatus")
                else o."Status" end::text,
           coalesce(nullif(trim(s."ManualAddress"), ''), o."ShippingAddress", ao."DeliveryAddress")::text,
           -- + (manual fee - the order's own fee) once a manual fee is set.
           coalesce(o."MoneyToCollect", a."Balance", public._automated_order_total(ao."OrderNo"))
             + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
           coalesce(o."Balance", a."Balance", public._automated_order_total(ao."OrderNo"))
             + coalesce(s."ManualDeliveryFee" - coalesce(o."DeliveryFee", 0), 0),
           s."Notes"::text,
           s."Latitude", s."Longitude", s."GeocodeStatus"::text, s."GeocodedAddress"::text,
           s."RouteName"::text, s."CreatedBy"::text,
           coalesce(
             nullif(trim(s."ManualNotePrint"), ''),
             nullif(trim(o."NotePrint"::text), ''),
             (select string_agg(nullif(trim(l."Note"::text), ''), '; ' order by l."LineID")
                from public."OnlineOrderLines" l
                where l."OrderID" = o."OrderID" and nullif(trim(l."Note"::text), '') is not null),
             nullif(trim(a."Order_Description"::text), ''),
             nullif(trim(ao."Notes"::text), '')
           ) as note_print,
           coalesce(nullif(trim(s."ManualContactNumber"), ''), nullif(trim(o."WalkinCustomerPhone"), ''),
                    nullif(trim(ao."CustomerPhone"), ''))::text as contact_number,
           (nullif(trim(s."ManualAddress"), '') is not null) as is_manual_address,
           case when a."TransactionNo" is not null then 'advance'
                when ao."OrderNo" is not null then 'automated'
                else 'online' end::text,
           coalesce(s."ManualDeliveryFee", o."DeliveryFee"),
           s."ManualDeliveryFee" is not null,
           dk.k,
           case when dk.k is null then null else coalesce(fm."FeeMode", 'once') end::text,
           coalesce(cs."OrderID", 'ADV-' || cs."AdvanceTransactionNo", cs."AutomatedOrderNo")::text,
           s."CombinedFeeWaived"
    from public."DeliveryStops" s
    left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
    left join public."AdvanceOrders" a on a."TransactionNo" = s."AdvanceTransactionNo"
    left join public."AdvanceOrderProduction" p on p."TransactionNo" = s."AdvanceTransactionNo"
    left join public."AutomatedOrders" ao on ao."OrderNo" = s."AutomatedOrderNo"
    join public."DeliveryTrucks" t on t."TruckID" = s."TruckID"
    cross join lateral (
      select public._delivery_drop_key(
               coalesce(nullif(trim(s."ManualCustomerName"), ''), nullif(trim(o."WalkinCustomerName"), ''),
                        o."CustomerName", a."CustomerName", ao."CustomerName"),
               coalesce(nullif(trim(s."ManualAddress"), ''), o."ShippingAddress", ao."DeliveryAddress"),
               s."GeocodedAddress") as k
    ) dk
    left join public."DeliveryDropFeeModes" fm on fm."DeliveryDate" = s."DeliveryDate" and fm."DropKey" = dk.k
    left join public."DeliveryStops" cs on cs."StopID" = s."FeeCombinedWithStopID"
    where s."DeliveryDate" >= p_start_date and s."DeliveryDate" < p_end_date
      and (o."OrderID" is not null or a."TransactionNo" is not null or ao."OrderNo" is not null)
    order by s."DeliveryDate", s."StopSequence";
end;
$$;

grant execute on function public.admin_list_delivery_stops(text, text, date, date) to anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- 7. Combine the drops already on the calendar from today on (stops already Done are left alone).

do $$
declare
  v_date date;
begin
  for v_date in
    select distinct "DeliveryDate" from public."DeliveryStops"
    where "DeliveryDate" >= (now() at time zone 'Asia/Manila')::date
    order by 1
  loop
    perform public._delivery_rebalance_date(v_date);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Verification - one result: pieces in place, then every combined drop from today on.

select 'setup' as section, x.item, x.ok as detail
from (values
  ('DeliveryStops.CombinedFeeWaived',
     exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'DeliveryStops' and column_name = 'CombinedFeeWaived')::text),
  ('DeliveryStops.FeeCombinedWithStopID',
     exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'DeliveryStops' and column_name = 'FeeCombinedWithStopID')::text),
  ('table DeliveryDropFeeModes', (to_regclass('public."DeliveryDropFeeModes"') is not null)::text),
  ('function staff_set_delivery_drop_fee_mode',
     exists (select 1 from pg_proc where proname = 'staff_set_delivery_drop_fee_mode')::text),
  ('admin_list_delivery_stops returns drop_key',
     (pg_get_function_result('public.admin_list_delivery_stops(text, text, date, date)'::regprocedure) like '%drop_key%')::text),
  ('trigger TR_DeliveryStops_RebalanceDrops_InsDel',
     exists (select 1 from pg_trigger where tgname = 'TR_DeliveryStops_RebalanceDrops_InsDel')::text),
  ('trigger TR_DeliveryStops_RebalanceDrops_Upd',
     exists (select 1 from pg_trigger where tgname = 'TR_DeliveryStops_RebalanceDrops_Upd')::text),
  ('trigger TR_OnlineOrders_RebalanceDrops',
     exists (select 1 from pg_trigger where tgname = 'TR_OnlineOrders_RebalanceDrops')::text)
) as x(item, ok)
union all
select 'combined drop ' || s."DeliveryDate"::text,
       coalesce(s."OrderID", 'ADV-' || s."AdvanceTransactionNo", s."AutomatedOrderNo"),
       case when s."FeeCombinedWithStopID" is null then 'carries the fee'
            else 'combined with ' || coalesce(c."OrderID", 'ADV-' || c."AdvanceTransactionNo", c."AutomatedOrderNo")
                 || coalesce(' - fee ' || s."CombinedFeeWaived"::text || ' taken off',
                             case when coalesce(s."ManualDeliveryFee", o."DeliveryFee", 0) > 0
                                  then ' - fee ' || coalesce(s."ManualDeliveryFee", o."DeliveryFee")::text || ' already paid, NOT taken off'
                                  else ' - had no fee of its own' end) end
from public."DeliveryStops" s
left join public."DeliveryStops" c on c."StopID" = s."FeeCombinedWithStopID"
left join public."OnlineOrders" o on o."OrderID" = s."OrderID"
where s."DeliveryDate" >=(now() at time zone 'Asia/Manila')::date
  and (s."FeeCombinedWithStopID" is not null
       or exists (select 1 from public."DeliveryStops" o2 where o2."FeeCombinedWithStopID" = s."StopID"))
order by 1, 2;
