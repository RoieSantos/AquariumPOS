-- Advance Orders: VOID a wrongly punched advance order - per "if a cashier wrongly punch a transaction
-- (advance order) how can they reverse it?" -> a Void on the POS: full refund, the cashier approves it
-- themselves (who / when / why is recorded), for an order from today or yesterday ("can we allow next day").
--
-- The POS (AdvanceOrdersHeaderForm "Void Order") refunds every payment on the receipt (negative
-- TransPaymentEntry rows dated at the void, in the open shift: a same-day void nets to zero, a next-day one
-- comes out of today's drawer / EOD / Dashboard tender split) and flags its local
-- AdvanceOrderHeader IsVoid. Nothing is deleted - the normal advance-order sync then sends IsVoid /
-- VoidedAtUtc / VoidedBy / VoidReason / VoidRefund here (a delete would come straight back: the 5-minute
-- bulk sync re-inserts any missing row). Before voiding, the POS asks pos_check_advance_order_void, which
-- refuses an order older than yesterday (Manila) or already at To Ship / Shipped / Delivered.
--
-- When AdvanceOrders."IsVoid" turns true (_advance_order_void_trigger -> _advance_order_process_void):
--   * its delivery stops are removed;
--   * serials held (RESERVED) or tagged SOLD for 'ADV-<no>' go back IN_STOCK;
--   * makers are unassigned (they drop off every maker list) and AdvanceOrderProduction."VoidedAtUtc" is
--     set, so _advance_order_prod_status says 'Voided' everywhere it's shown;
--   * the Item Ledger reconcile puts back anything already taken out (a voided order wants nothing);
--   * a row in AdvanceOrderVoids records it (who / when / why / refund / makers it had / any error).
--   It never raises - a failure here must not fail the POS sync (one bad row would stop the whole bulk run).
-- After that the order is read-only on the portal: AdvanceOrderProduction refuses changes (assign, stages,
-- send back, delivery fee...), it can't get a new delivery stop or transfer line (Request Stock Transfer is
-- refused - _advance_order_can_request_transfer), serials can't be reserved or tagged to it.
-- Open Transfer Orders already linked to it are NOT touched (shared documents) - units received for it
-- later just go In Stock (_serial_order_is_open is false for a voided order). Cancel them by hand.
--
-- Also re-created with a voided filter: staff_get_advance_orders_to_follow, admin_list_deliverable_online_orders,
-- admin_get_dashboard_daily_advance_orders, admin_get_my_view (customer deposits), and
-- _serial_order_is_open / _ile_reconcile_advance_order / _advance_order_prod_status.
--
-- Run AFTER supabase_advance_order_transfer_link.sql, supabase_tag_serials_fulfilled_order.sql,
-- supabase_delivery_assign_assigned_status.sql, supabase_advance_order_to_follow.sql,
-- supabase_dashboard_my_view.sql, supabase_item_ledger_advance_orders.sql, supabase_serial_order_reservation.sql
-- and supabase_delivery_stop_done_post.sql. If any of those is re-run later, run this one again afterwards.
-- Run it BEFORE the POS build with the Void button is used. Safe to re-run. Ends with ONE result: OK / FIX.

set lock_timeout = '10s';

-- ============================================================================
-- 1. Columns + the void record
-- ============================================================================
alter table public."AdvanceOrders" add column if not exists "IsVoid" boolean not null default false;
alter table public."AdvanceOrders" add column if not exists "VoidedAtUtc" timestamptz;
alter table public."AdvanceOrders" add column if not exists "VoidedBy" varchar(100);
alter table public."AdvanceOrders" add column if not exists "VoidReason" varchar(500);
alter table public."AdvanceOrders" add column if not exists "VoidRefund" numeric(18, 2);

-- Portal copy, so _advance_order_prod_status (which only gets the production row) can say 'Voided'.
alter table public."AdvanceOrderProduction" add column if not exists "VoidedAtUtc" timestamptz;

create table if not exists public."AdvanceOrderVoids" (
  "TransactionNo" varchar(100) primary key,
  "VoidedAtUtc" timestamptz,
  "VoidedBy" varchar(100),
  "VoidReason" varchar(500),
  "VoidRefund" numeric(18, 2),
  "TankMaker" text,              -- who was assigned when it was voided (unassigned by the void)
  "StandMaker" text,
  "StopsRemoved" int not null default 0,
  "SerialsReleased" int not null default 0,
  "ProcessedAtUtc" timestamptz not null default now(),
  "Errors" text                  -- null = every step worked
);
alter table public."AdvanceOrderVoids" enable row level security;   -- no policies: read through the RPCs below

-- ============================================================================
-- 2. 'Voided' stage (copy of supabase_delivery_stop_done_post.sql's version + the first line)
-- ============================================================================
create or replace function public._advance_order_prod_status(p public."AdvanceOrderProduction")
returns text
language sql
immutable
as $$
  select case
    when p."VoidedAtUtc" is not null then 'Voided'
    when p."DeliveredAtUtc" is not null then 'Delivered'
    when p."ShippedAtUtc" is not null then 'Shipped'
    when p."ToShipAtUtc" is not null then 'To Ship'
    when p."TankMaker" is null and p."StandMaker" is null then null
    when (p."TankMaker" is not null and p."TankDoneAtUtc" is null)
      or (p."StandMaker" is not null and p."StandDoneAtUtc" is null) then 'Assigned'
    else 'Production Done'
  end;
$$;

revoke execute on function public._advance_order_prod_status(public."AdvanceOrderProduction") from public, anon, authenticated;

create or replace function public._advance_order_is_void(p_no text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select a."IsVoid" from public."AdvanceOrders" a where a."TransactionNo" = p_no), false);
$$;

revoke execute on function public._advance_order_is_void(text) from public, anon, authenticated;

-- ============================================================================
-- 3. Read-only once voided
-- ============================================================================
create or replace function public._advance_order_production_void_guard()
returns trigger
language plpgsql
as $$
begin
  if old."VoidedAtUtc" is not null then
    raise exception 'Advance order % was voided on the POS - it can''t be changed.', old."TransactionNo";
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_AdvanceOrderProduction_VoidGuard" on public."AdvanceOrderProduction";
create trigger "TR_AdvanceOrderProduction_VoidGuard"
  before update on public."AdvanceOrderProduction"
  for each row execute function public._advance_order_production_void_guard();

create or replace function public._delivery_stop_void_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new."AdvanceTransactionNo" is not null and public._advance_order_is_void(new."AdvanceTransactionNo") then
    raise exception 'Advance order % was voided on the POS - it can''t be scheduled for delivery.', new."AdvanceTransactionNo";
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_DeliveryStops_VoidGuard" on public."DeliveryStops";
create trigger "TR_DeliveryStops_VoidGuard"
  before insert or update of "AdvanceTransactionNo" on public."DeliveryStops"
  for each row execute function public._delivery_stop_void_guard();

-- A new link to a voided order (Request Stock Transfer, or typing ADV-<no> as a line's Order ID). Lines
-- that already carried it keep working (edit / ship / receive).
create or replace function public._transfer_line_void_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text := upper(trim(coalesce(new."Order ID", '')));
begin
  if v_id not like 'ADV-%' then
    return new;
  end if;
  if tg_op = 'UPDATE' and v_id = upper(trim(coalesce(old."Order ID", ''))) then
    return new;
  end if;
  if public._advance_order_is_void(substr(v_id, 5)) then
    raise exception 'Advance order % was voided on the POS - it can''t be linked to a transfer.', substr(v_id, 5);
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_Transfer_Line_VoidGuard" on public."Transfer_Line";
create trigger "TR_Transfer_Line_VoidGuard"
  before insert or update of "Order ID" on public."Transfer_Line"
  for each row execute function public._transfer_line_void_guard();

-- Nobody may Request Stock Transfer for a voided order: the transfer plan's can_request comes back false (so
-- the portal hides the button) and staff_create_advance_order_transfer refuses. Copy of
-- supabase_advance_order_transfer_link.sql + the void line.
create or replace function public._advance_order_can_request_transfer(p_username text, p_no text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not public._advance_order_is_void(p_no)
     and public._advance_order_can_view(p_username, p_no)
     and (public._production_is_manager(p_username) or public._advance_order_is_viewer(p_username));
$$;

revoke execute on function public._advance_order_can_request_transfer(text, text) from public, anon, authenticated;

-- Tag Serials (fulfilled orders) never applies to a voided order. Copy of supabase_tag_serials_fulfilled_order.sql
-- + the VoidedAtUtc line.
create or replace function public._serial_order_is_fulfilled(p_link text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_link ilike 'ADV-%' then exists (
      select 1 from public."AdvanceOrderProduction" p
      where p."TransactionNo" = substr(p_link, 5)
        and p."VoidedAtUtc" is null
        and (p."ShippedAtUtc" is not null or p."DeliveredAtUtc" is not null))
    else exists (
      select 1 from public."OnlineOrders" o
      where o."OrderID" = p_link
        and (lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', 'completed')
             or (o."ReceivedAtShop" is true and o."PickedUpAtUtc" is not null)))
  end;
$$;

revoke execute on function public._serial_order_is_fulfilled(text) from public, anon, authenticated;

-- ============================================================================
-- 4. A voided order is no longer "open" for serial holds (copy of supabase_serial_order_reservation.sql +
--    the IsVoid line) - e.g. a unit received on its transfer goes In Stock, not Reserved.
-- ============================================================================
create or replace function public._serial_order_is_open(p_link text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    -- AdvanceOrders has no cancel status - open = still there, not voided and not Shipped.
    when p_link ilike 'ADV-%' then exists (
      select 1 from public."AdvanceOrders" a
      where a."TransactionNo" = substr(p_link, 5)
        and not coalesce(a."IsVoid", false)
        and not exists (select 1 from public."AdvanceOrderProduction" p
                        where p."TransactionNo" = a."TransactionNo" and p."ShippedAtUtc" is not null))
    else exists (
      select 1 from public."OnlineOrders" o
      where o."OrderID" = p_link
        and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
        and case when o."ReceivedAtShop" is true then o."PickedUpAtUtc" is null
                 else lower(trim(coalesce(o."Status", ''))) not in
                        ('to ship', 'shipped', 'delivered', 'completed', 'returned', 'returning') end)
  end;
$$;

revoke execute on function public._serial_order_is_open(text) from public, anon, authenticated;

-- ============================================================================
-- 5. What a void does on the portal. Every step is on its own - one failing (e.g. a delivery stop another
--    table still points at) is written to AdvanceOrderVoids."Errors" and the rest still run. Never raises.
--    Safe to call again (the trigger only calls it when IsVoid turns true).
-- ============================================================================
create or replace function public._advance_order_process_void(p_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_link text := 'ADV-' || p_no;
  v_order public."AdvanceOrders";
  v_by text;
  v_tank text;
  v_stand text;
  v_stops int := 0;
  v_serials int := 0;
  v_n int;
  v_errors text[] := '{}';
begin
  select * into v_order from public."AdvanceOrders" where "TransactionNo" = p_no;
  if not found or not coalesce(v_order."IsVoid", false) then
    return;
  end if;
  v_by := left('void: ' || coalesce(nullif(trim(v_order."VoidedBy"), ''), 'POS'), 100);

  select p."TankMaker", p."StandMaker" into v_tank, v_stand
    from public."AdvanceOrderProduction" p where p."TransactionNo" = p_no;

  -- Delivery stops first: their delete trigger may still write the order's delivery fee, which the
  -- production row refuses once it's voided (step 3).
  begin
    delete from public."DeliveryStops" where "AdvanceTransactionNo" = p_no;
    get diagnostics v_stops = row_count;
  exception when others then
    v_errors := v_errors || ('delivery stops: ' || sqlerrm);
  end;

  begin
    v_serials := public._serial_release_order_reservations(v_link, v_by);
    update public."ItemSerialTracking"
       set "Status" = 'IN_STOCK', "SoldOnlineOrderId" = null, "SoldReceiptNo" = null,
           "UpdatedAtUtc" = now(), "UpdatedBy" = v_by
     where "Status" = 'SOLD' and "SoldOnlineOrderId" = v_link;
    get diagnostics v_n = row_count;
    v_serials := v_serials + v_n;
  exception when others then
    v_errors := v_errors || ('serials: ' || sqlerrm);
  end;

  -- 'Voided' stage + makers off every maker list. Inserting the row also runs the Item Ledger reconcile
  -- (TR_AdvanceOrderProduction_ItemLedger); step 4 covers an order that already had one.
  begin
    insert into public."AdvanceOrderProduction" ("TransactionNo", "VoidedAtUtc", "UpdatedAtUtc", "UpdatedBy")
    values (p_no, coalesce(v_order."VoidedAtUtc", now()), now(), v_by)
    on conflict ("TransactionNo") do update
      set "VoidedAtUtc" = excluded."VoidedAtUtc", "TankMaker" = null, "StandMaker" = null,
          "UpdatedAtUtc" = now(), "UpdatedBy" = excluded."UpdatedBy"
      where "AdvanceOrderProduction"."VoidedAtUtc" is null;
  exception when others then
    v_errors := v_errors || ('production row: ' || sqlerrm);
  end;

  -- Puts back anything already taken out of stock for ADV-<no> (errors land in ItemLedgerAdvanceOrderSync).
  perform public._ile_try_reconcile_advance_order(p_no);

  insert into public."AdvanceOrderVoids" ("TransactionNo", "VoidedAtUtc", "VoidedBy", "VoidReason", "VoidRefund",
                                          "TankMaker", "StandMaker", "StopsRemoved", "SerialsReleased", "ProcessedAtUtc", "Errors")
  values (p_no, v_order."VoidedAtUtc", v_order."VoidedBy", v_order."VoidReason", v_order."VoidRefund",
          v_tank, v_stand, v_stops, v_serials, now(), nullif(array_to_string(v_errors, ' | '), ''))
  on conflict ("TransactionNo") do update
    set "VoidedAtUtc" = excluded."VoidedAtUtc", "VoidedBy" = excluded."VoidedBy", "VoidReason" = excluded."VoidReason",
        "VoidRefund" = excluded."VoidRefund",
        "TankMaker" = coalesce("AdvanceOrderVoids"."TankMaker", excluded."TankMaker"),
        "StandMaker" = coalesce("AdvanceOrderVoids"."StandMaker", excluded."StandMaker"),
        "StopsRemoved" = "AdvanceOrderVoids"."StopsRemoved" + excluded."StopsRemoved",
        "SerialsReleased" = "AdvanceOrderVoids"."SerialsReleased" + excluded."SerialsReleased",
        "ProcessedAtUtc" = now(), "Errors" = excluded."Errors";
exception when others then
  -- last resort - the POS sync must never fail because of a void
  raise warning 'Advance order % void processing failed: %', p_no, sqlerrm;
end;
$$;

revoke execute on function public._advance_order_process_void(text) from public, anon, authenticated;

create or replace function public._advance_order_void_trigger()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(new."IsVoid", false) and (tg_op = 'INSERT' or not coalesce(old."IsVoid", false)) then
    perform public._advance_order_process_void(new."TransactionNo");
  end if;
  return null;
end;
$$;

drop trigger if exists "TR_AdvanceOrders_Void" on public."AdvanceOrders";
create trigger "TR_AdvanceOrders_Void"
  after insert or update of "IsVoid" on public."AdvanceOrders"
  for each row execute function public._advance_order_void_trigger();

-- ============================================================================
-- 6. POS: may this order be voided? Called by the POS before it refunds anything (anon key, like the other
--    pos_ reads). Not on the portal yet = fine (the void goes up with its first sync).
-- ============================================================================
create or replace function public.pos_check_advance_order_void(p_transaction_no text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_no text := trim(coalesce(p_transaction_no, ''));
  v_void boolean;
  v_status text;
  v_date date;
  v_transfers int;
begin
  select coalesce(a."IsVoid", false), public._advance_order_prod_status(p), a."Date"
    into v_void, v_status, v_date
  from public."AdvanceOrders" a
  left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
  where a."TransactionNo" = v_no;

  if not found then
    return jsonb_build_object('found', false, 'ok', true, 'status', null, 'message', 'Not on the portal yet.');
  end if;
  if v_void then
    return jsonb_build_object('found', true, 'ok', true, 'status', 'Voided', 'message', 'Already voided on the portal.');
  end if;
  -- Today or yesterday only (same rule as the POS).
  if v_date is not null and v_date < (now() at time zone 'Asia/Manila')::date - 1 then
    return jsonb_build_object('found', true, 'ok', false, 'status', v_status,
      'message', format('Advance order %s is from %s - only orders from today or yesterday can be voided.', v_no, v_date));
  end if;
  if v_status in ('Shipped', 'Delivered') then
    return jsonb_build_object('found', true, 'ok', false, 'status', v_status,
      'message', format('Advance order %s is already %s on the portal - the goods have left, so this is a return, not a void.', v_no, v_status));
  end if;
  if v_status = 'To Ship' then
    return jsonb_build_object('found', true, 'ok', false, 'status', v_status,
      'message', format('Advance order %s is already Ready to Ship on the portal (its stock and serials are taken). Ask the Production Manager to Undo Stage first, then void it.', v_no));
  end if;

  select count(*) into v_transfers
  from public."Transfer_Line" l
  where upper(trim(coalesce(l."Order ID", ''))) = 'ADV-' || upper(v_no);

  return jsonb_build_object('found', true, 'ok', true, 'status', coalesce(v_status, 'New'), 'open_transfer_lines', v_transfers,
    'message', case when v_transfers > 0
                    then format('It has %s open stock transfer line(s) - tell the Production Manager to cancel them.', v_transfers)
                    else 'OK' end);
end;
$$;

revoke all on function public.pos_check_advance_order_void(text) from public;
grant execute on function public.pos_check_advance_order_void(text) to anon;

-- ============================================================================
-- 7. Portal: who voided which orders, for the Advance Orders tab's badge / card (same access as the list).
-- ============================================================================
drop function if exists public.staff_get_advance_order_voids(text, text, text[]);

create or replace function public.staff_get_advance_order_voids(p_admin_username text, p_admin_password text, p_nos text[])
returns table(transaction_no text, voided_at timestamptz, voided_by text, void_reason text, void_refund numeric, errors text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_branch text;
begin
  if public.is_admin_authorized(p_admin_username, p_admin_password) then
    v_branch := null;
  elsif public.is_staff_authorized(p_admin_username, p_admin_password) and public._advance_order_is_viewer(p_admin_username) then
    v_branch := public._advance_order_viewer_branch(p_admin_username);
  else
    raise exception 'Not authorized.';
  end if;

  return query
    select a."TransactionNo"::text, a."VoidedAtUtc", a."VoidedBy"::text, a."VoidReason"::text, a."VoidRefund", v."Errors"
    from public."AdvanceOrders" a
    left join public."AdvanceOrderVoids" v on v."TransactionNo" = a."TransactionNo"
    where a."IsVoid"
      and a."TransactionNo" = any(coalesce(p_nos, '{}'))
      and (v_branch is null or lower(trim(coalesce(a."Warehouse", ''))) = v_branch);
end;
$$;

grant execute on function public.staff_get_advance_order_voids(text, text, text[]) to anon;

-- ============================================================================
-- 8. Item Ledger: a voided order wants nothing (copy of supabase_item_ledger_advance_orders.sql + IsVoid) -
--    so whatever ADV-<no> already took out is put back.
-- ============================================================================
create or replace function public._ile_reconcile_advance_order(p_no text)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_start timestamptz;
  v_doc text := 'ADV-' || p_no;
  v_order record;
  v_found boolean;
  v_to_ship timestamptz;
  v_counts boolean;
  v_warehouse_id text;
  v_first boolean;
  v_date date;
  v_transaction_no bigint;
  v_row record;
  v_posted int := 0;
begin
  select s."SalesPostingStartUtc" into v_start from public."ItemLedgerSetup" s limit 1;
  if v_start is null then
    return 0;
  end if;

  -- One reconcile per order at a time (the POS sync writes several lines back to back).
  perform pg_advisory_xact_lock(hashtext('ile_advance|' || p_no));

  select a."Warehouse", nullif(trim(coalesce(a."OnlineOrderID", '')), '') as online_order_id,
         coalesce(a."IsVoid", false) as is_void into v_order
    from public."AdvanceOrders" a where a."TransactionNo" = p_no;
  v_found := found;

  select p."ToShipAtUtc" into v_to_ship
    from public."AdvanceOrderProduction" p where p."TransactionNo" = p_no;

  v_counts := v_found
    and not v_order.is_void   -- voided on the POS (supabase_advance_order_void.sql)
    and v_to_ship is not null and v_to_ship >= v_start
    -- Already taken out through its old Pancake order - never twice.
    and not (v_order.online_order_id is not null and exists (
      select 1 from public."ItemLedgerEntries" e
      where e."DocumentType" = 'Sales Order' and e."DocumentNo" = v_order.online_order_id));

  if v_counts then
    select w."ID" into v_warehouse_id
      from public."Warehouses" w
      where lower(trim(w."Name")) = lower(trim(coalesce(v_order."Warehouse", '')))
      limit 1;
  end if;

  v_first := not exists (
    select 1 from public."ItemLedgerEntries" e where e."DocumentType" = 'Advance Order' and e."DocumentNo" = v_doc
  );

  -- First posting dated to the day it went To Ship; later corrections dated today.
  v_date := case
    when v_first and v_to_ship is not null then (v_to_ship at time zone 'Asia/Manila')::date
    else public._ile_today()
  end;

  for v_row in
    with lines as (
      select li.item_code as raw_item, li.variation_id as raw_variant, li.quantity as qty
      from public._advance_order_line_items(p_no) li
      where v_counts
        and li.item_code is not null
        and li.reason not like 'no - SET%'
        and li.quantity > 0
    ),
    desired as (
      select r.item_code, r.variant_id, sum(li.qty) as qty
      from lines li
      cross join lateral public._ile_try_resolve_stock_key(li.raw_item, li.raw_variant) r
      group by r.item_code, r.variant_id
    ),
    posted as (
      select e."ItemCode" as item_code, e."VariantId" as variant_id, e."WarehouseId" as warehouse_id, -sum(e."Quantity") as qty
      from public."ItemLedgerEntries" e
      where e."DocumentType" = 'Advance Order' and e."DocumentNo" = v_doc
      group by e."ItemCode", e."VariantId", e."WarehouseId"
    ),
    -- Anything posted to a different warehouse than the order now says is put back there and taken
    -- from the right one.
    wanted as (
      select d.item_code, d.variant_id, v_warehouse_id as warehouse_id, d.qty from desired d
    )
    select
      coalesce(w.item_code, p.item_code) as item_code,
      coalesce(w.variant_id, p.variant_id) as variant_id,
      coalesce(w.warehouse_id, p.warehouse_id) as warehouse_id,
      coalesce(w.qty, 0) - coalesce(p.qty, 0) as delta
    from wanted w
    full join posted p
      on w.item_code = p.item_code
     and w.variant_id is not distinct from p.variant_id
     and w.warehouse_id = p.warehouse_id
    where coalesce(w.qty, 0) - coalesce(p.qty, 0) <> 0
  loop
    if v_row.warehouse_id is null then
      raise exception 'Advance order % is from warehouse "%", which is not in Warehouses - its items cannot be taken out of stock.',
        p_no, coalesce(v_order."Warehouse", '(blank)');
    end if;

    v_transaction_no := coalesce(v_transaction_no, nextval('public.ile_transaction_no_seq'));

    perform public._ile_post(
      'Sale',
      v_row.item_code,
      v_row.variant_id,
      v_row.warehouse_id,
      -v_row.delta,
      v_date,
      'Advance Order',
      v_doc,
      case
        when v_first then 'Advance order ' || p_no || ' ready to ship'
        when v_counts then 'Advance order ' || p_no || ' changed'
        when v_order.is_void then 'Advance order ' || p_no || ' voided'
        else 'Advance order ' || p_no || ' back before To Ship'
      end,
      v_transaction_no,
      'system'
    );
    v_posted := v_posted + 1;
  end loop;

  insert into public."ItemLedgerAdvanceOrderSync" ("TransactionNo", "ReconciledAtUtc", "LastError")
  values (p_no, now(), null)
  on conflict ("TransactionNo") do update set "ReconciledAtUtc" = now(), "LastError" = null;

  return v_posted;
end;
$$;

revoke execute on function public._ile_reconcile_advance_order(text) from public, anon, authenticated;

-- ============================================================================
-- 9. Lists / dashboards that must leave voided orders out (copies + one line each)
-- ============================================================================

-- TO FOLLOW (supabase_advance_order_to_follow.sql): not for a voided order.
drop function if exists public.staff_get_advance_orders_to_follow(text, text, text[]);

create or replace function public.staff_get_advance_orders_to_follow(
  p_admin_username text,
  p_admin_password text,
  p_nos text[] default null
)
returns table(
  transaction_no text,
  units_total int,
  units_tagged int,
  units_to_follow int,  -- serial-tracked units with no serial yet
  to_follow boolean     -- the TO FOLLOW badge (rules above)
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_branch text; -- null = all branches; else a Store Manager's own branch (lower-cased)
begin
  -- Same access as admin_list_advance_orders (supabase_advance_orders_store_manager_view.sql).
  if public.is_admin_authorized(p_admin_username, p_admin_password) then
    v_branch := null;
  elsif public.is_staff_authorized(p_admin_username, p_admin_password) and public._advance_order_is_viewer(p_admin_username) then
    v_branch := public._advance_order_viewer_branch(p_admin_username);
  else
    raise exception 'Not authorized.';
  end if;

  return query
    with candidates as (
      select a."TransactionNo"::text as no,
             (coalesce(a."FullyPaid", false) or coalesce(a."Balance", 0) <= 0)
               and coalesce(public._advance_order_prod_status(p), '') not in ('Shipped', 'Delivered', 'Voided')
               and (a."Date" >= public._advance_order_to_follow_since() or p."TransactionNo" is not null) as eligible
      from public."AdvanceOrders" a
      left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
      where (v_branch is null or lower(trim(coalesce(a."Warehouse", ''))) = v_branch)
        and (case when p_nos is null then true else a."TransactionNo" = any(p_nos) end)
    ),
    -- the full list (p_nos null) only needs the TO FOLLOW ones - don't count serials on every old order
    checked as (
      select c.* from candidates c where p_nos is not null or c.eligible
    )
    select c.no, u.units_total, u.units_tagged, u.units_untagged,
           c.eligible and u.units_untagged > 0
    from checked c
    cross join lateral public._advance_order_unit_counts(c.no) u
    where p_nos is not null or u.units_untagged > 0
    order by c.no;
end;
$$;

grant execute on function public.staff_get_advance_orders_to_follow(text, text, text[]) to anon;

-- Delivery calendar's Add order search (supabase_delivery_assign_assigned_status.sql): no voided advance orders.
drop function if exists public.admin_list_deliverable_online_orders(text, text, text, int, int, text, text);

create or replace function public.admin_list_deliverable_online_orders(p_admin_username text, p_admin_password text, p_search text default null, p_page int default 1, p_page_size int default 50,
  p_sort_column text default null, p_sort_dir text default 'asc')
returns table(
  order_id text,                 -- OnlineOrders.OrderID / AdvanceOrders.TransactionNo / AutomatedOrders.OrderNo, by source
  source text,                   -- 'online' | 'advance' | 'automated'
  customer_name text,
  status text,
  shipping_address text,
  contact_number text,
  money_to_collect numeric,
  balance numeric,
  estimated_delivery_date date,
  is_walk_in boolean,
  total_count bigint,
  automated_order_no text        -- AutomatedOrders.OrderNo ("AO-00039") behind the order, if any
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_sort text := lower(coalesce(p_sort_column, ''));
  v_desc boolean := lower(coalesce(p_sort_dir, 'asc')) = 'desc';
  v_is_super_user boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce("SuperUser", false) into v_is_super_user
  from public."StaffUsers"
  where "Username" = p_admin_username;

  return query
    with candidates as (
      select o."OrderID"::text as id, 'online'::text as src,
             coalesce(nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName")::text as cust,
             o."Status"::text as st, o."ShippingAddress"::text as addr,
             coalesce(nullif(trim(o."WalkinCustomerPhone"), ''), o."ShippingPhone")::text as phone,
             o."MoneyToCollect" as mtc, o."Balance" as bal, o."EstimatedDeliveryDate" as edd,
             (coalesce(o."ReceivedAtShop", false)
              or lower(trim(coalesce(o."CustomerName", ''))) = 'pos walkin orders'
              or lower(trim(coalesce(o."ShippingAddress", ''))) = 'walkin') as walk_in,
             o."Last_Updated_At" as sort_at,
             (select ao."OrderNo"::text from public."AutomatedOrders" ao
              where ao."PancakeReceiptNo" = o."OrderID" order by ao."OrderNo" limit 1) as ao_no
      from public."OnlineOrders" o
      where (
          lower(o."Status") in ('confirmed', 'printed', 'assigned', 'to ship', 'shipped') -- + assigned (this file)
          or (coalesce(v_is_super_user, false) and lower(o."Status") in ('canceled', 'cancelled'))
        )
        and not exists (select 1 from public."DeliveryStops" s where s."OrderID" = o."OrderID")
        -- its advance order (if any) is already scheduled under the advance number
        and not exists (
          select 1 from public."AdvanceOrders" a
          join public."DeliveryStops" s on s."AdvanceTransactionNo" = a."TransactionNo"
          where nullif(trim(a."OnlineOrderID"), '') = o."OrderID")
        -- its automated order is already scheduled under the AO number
        and not exists (
          select 1 from public."AutomatedOrders" ao
          join public."DeliveryStops" s on s."AutomatedOrderNo" = ao."OrderNo"
          where ao."PancakeReceiptNo" = o."OrderID")
        and (v_search is null
             or o."OrderID" ilike '%' || v_search || '%'
             or o."CustomerName" ilike '%' || v_search || '%'
             or o."WalkinCustomerName" ilike '%' || v_search || '%'
             or exists (select 1 from public."AutomatedOrders" ao
                        where ao."PancakeReceiptNo" = o."OrderID"
                          and ao."OrderNo" ilike '%' || v_search || '%'))

      union all

      select a."TransactionNo"::text, 'advance',
             a."CustomerName"::text,
             ('Advance' || coalesce(' - ' || public._advance_order_prod_status(p), ''))::text,
             null::text, null::text,
             a."Balance", a."Balance", null::date,
             false,
             greatest(a."DatePaid",
                      (a."Date" + coalesce(public._advance_order_time(a."Time"), time '00:00')) at time zone 'Asia/Manila'),
             null::text
      from public."AdvanceOrders" a
      left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
      where not exists (select 1 from public."DeliveryStops" s where s."AdvanceTransactionNo" = a."TransactionNo")
        and not coalesce(a."IsVoid", false)
        -- its linked online order is already scheduled
        and not exists (select 1 from public."DeliveryStops" s
                        where s."OrderID" = nullif(trim(a."OnlineOrderID"), ''))
        and (v_search is null
             or a."TransactionNo" ilike '%' || v_search || '%'
             or a."ReceiptNo" ilike '%' || v_search || '%'
             or a."CustomerName" ilike '%' || v_search || '%'
             or a."OnlineOrderID" ilike '%' || v_search || '%')

      union all

      -- Automated orders with no online order yet (draft awaiting Confirm Order).
      select ao."OrderNo"::text, 'automated',
             ao."CustomerName"::text,
             (ao."Status" || public._automated_order_pending_label(ao."PancakeSyncStatus"))::text,
             ao."DeliveryAddress"::text, ao."CustomerPhone"::text,
             public._automated_order_total(ao."OrderNo"), public._automated_order_total(ao."OrderNo"),
             null::date,
             false,
             ao."UpdatedAtUtc",
             ao."OrderNo"::text
      from public."AutomatedOrders" ao
      where not exists (select 1 from public."OnlineOrders" o
                        where o."OrderID" = nullif(trim(ao."PancakeReceiptNo"), ''))
        and (lower(ao."Status") not in ('cancelled', 'canceled') or coalesce(v_is_super_user, false))
        and not exists (select 1 from public."DeliveryStops" s where s."AutomatedOrderNo" = ao."OrderNo")
        and (v_search is null
             or ao."OrderNo" ilike '%' || v_search || '%'
             or ao."CustomerName" ilike '%' || v_search || '%'
             or ao."CustomerPhone" ilike '%' || v_search || '%')
    ),
    keyed as (
      select c.*,
             -- order numbers sort as numbers (9 before 10), anything non-numeric after them
             case when v_sort = 'order_id' and c.id ~ '^\d+$' then c.id::numeric end as num_key,
             case v_sort
               when 'order_id' then lower(c.id)
               when 'customer_name' then lower(nullif(trim(c.cust), ''))
               when 'status' then lower(nullif(trim(c.st), ''))
               when 'shipping_address' then lower(nullif(trim(c.addr), ''))
               when 'type' then case when c.src = 'advance' then 'advance' when c.src = 'automated' then 'order form'
                                     when c.walk_in then 'walk-in' else 'online' end
             end as text_key
      from candidates c
    )
    select k.id, k.src, k.cust, k.st, k.addr, k.phone, k.mtc, k.bal, k.edd, k.walk_in,
           count(*) over(), k.ao_no
    from keyed k
    order by case when not v_desc then k.num_key end asc nulls last,
             case when v_desc then k.num_key end desc nulls last,
             case when not v_desc then k.text_key end asc nulls last,
             case when v_desc then k.text_key end desc nulls last,
             k.sort_at desc nulls last, k.id desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_deliverable_online_orders(text, text, text, int, int, text, text) to anon;

-- Dashboard: today's advance orders (supabase_dashboard_daily_advance_orders.sql) - voided ones left out.
drop function if exists public.admin_get_dashboard_daily_advance_orders(text, text, text);

create or replace function public.admin_get_dashboard_daily_advance_orders(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text default null
)
returns table(
  warehouse_name text,
  order_count int,
  net_amount numeric,
  downpayment numeric,
  balance numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_wh text := nullif(trim(coalesce(p_warehouse_name, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select coalesce(nullif(trim(a."Warehouse"), ''), '(No warehouse)')::text,
           count(*)::int,
           coalesce(sum(a."NetAmount"), 0)::numeric,
           coalesce(sum(a."Downpayment"), 0)::numeric,
           coalesce(sum(greatest(coalesce(a."Balance", 0), 0)), 0)::numeric
    from public."AdvanceOrders" a
    where a."Date" = v_today
      and not coalesce(a."IsVoid", false)
      and (v_wh is null or a."Warehouse" = v_wh)
    group by 1
    order by 1;
end;
$$;

grant execute on function public.admin_get_dashboard_daily_advance_orders(text, text, text) to anon;

-- Dashboard: today's advance collections by tender (supabase_advance_order_payments.sql) - unchanged copy on
-- purpose: voided orders are NOT filtered, so a next-day void's refund (negative row dated today) shows as money
-- out today and matches the drawer; a same-day void's payment and refund net to zero. (An earlier version of
-- this file filtered them out - re-running puts this one back.)
drop function if exists public.admin_get_dashboard_daily_advance_tender(text, text, text);

create or replace function public.admin_get_dashboard_daily_advance_tender(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text default null
)
returns table(
  method_name text,
  amount numeric,
  payment_count int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_wh text := nullif(trim(coalesce(p_warehouse_name, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select coalesce(nullif(upper(trim(p."TenderTypeCode")), ''), '(No tender)')::text,
           coalesce(sum(p."Amount"), 0)::numeric,
           count(*)::int
    from public."AdvanceOrderPayments" p
    left join public."AdvanceOrders" a on a."TransactionNo" = p."AdvanceTransactionNo"
    where p."Date" = v_today
      and (v_wh is null or coalesce(a."Warehouse", p."Warehouse") = v_wh)
    group by 1
    order by 2 desc;
end;
$$;

grant execute on function public.admin_get_dashboard_daily_advance_tender(text, text, text) to anon;

-- My View (supabase_dashboard_my_view.sql): a voided order's deposit was refunded - not a customer deposit.
drop function if exists public.admin_get_my_view(text, text, date, date);

create or replace function public.admin_get_my_view(
  p_admin_username text,
  p_admin_password text,
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_days int;
  v_trend jsonb;
  v_position jsonb;
  v_owner jsonb;
  v_cash jsonb;
  v_upcoming jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'Pick a valid date range.';
  end if;
  v_days := p_to - p_from + 1;

  -- 6 calendar months ending with p_to's month (the current month runs to date).
  select jsonb_agg(jsonb_build_object('month', m.month_start) || public._my_view_pnl(m.month_start, least(m.month_end, v_today))
                   order by m.month_start)
  into v_trend
  from (
    select gs::date as month_start, (gs + interval '1 month' - interval '1 day')::date as month_end
    from generate_series(date_trunc('month', p_to) - interval '5 months', date_trunc('month', p_to), interval '1 month') gs
  ) m;

  -- Balance snapshot, as of today.
  with stock as (
    select e."ItemCode", sum(e."Quantity") as qty
    from public."ItemLedgerEntries" e
    group by e."ItemCode"
    having sum(e."Quantity") > 0
  ),
  vendor_ap as (
    select coalesce((select sum(b."Amount") from public."VendorBills" b where not b."IsVoid"), 0)
         - coalesce((select sum(p."Amount") from public."VendorPayments" p where not p."IsVoid"), 0) as ap
  ),
  open_vendor_bills as (
    select b."BillNo", b."DueDate",
           b."Amount" - coalesce((select sum(p."Amount") from public."VendorPayments" p
                                  where p."BillNo" = b."BillNo" and not p."IsVoid"), 0) as open_amount
    from public."VendorBills" b
    where not b."IsVoid"
  ),
  bill_unpaid as (
    select b."BillID", b."Name", b."ExpectedAmount", d.due_date
    from public."BusinessBills" b
    cross join lateral public._business_bill_due_dates(b."FirstDueDate", b."Frequency", b."FirstDueDate", v_today + 30) d
    where b."IsActive"
      and not exists (select 1 from public."BusinessBillPayments" p
                      where p."BillID" = b."BillID" and p."DueDate" = d.due_date and not p."IsVoid")
  ),
  adv as (
    select a."TransactionNo",
           case when a."FullyPaid" then coalesce(a."NetAmount", 0)
                else greatest(coalesce(a."NetAmount", 0) - coalesce(a."Balance", 0), coalesce(a."Downpayment", 0)) end as deposit
    from public."AdvanceOrders" a
    where nullif(trim(coalesce(a."OnlineOrderID", '')), '') is null
      and not coalesce(a."IsVoid", false)
  )
  select jsonb_build_object(
    'inventory_value', (select coalesce(round(sum(s.qty * coalesce(i."Cost", 0)), 2), 0)
                        from stock s left join public."Items" i on i."Code" = s."ItemCode"),
    'inventory_uncosted_items', (select count(*) from stock s left join public."Items" i on i."Code" = s."ItemCode"
                                 where coalesce(i."Cost", 0) = 0),
    -- Per "dont include Delivered / Shipped / Cancelled / New Status": only orders still in progress.
    'receivables', (select coalesce(sum(o."Balance"), 0) from public."OnlineOrders" o
                    where o."Balance" > 0 and o."ReceivedAtShop" is not true
                      and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled', 'delivered', 'shipped', 'new')),
    'receivables_count', (select count(*) from public."OnlineOrders" o
                          where o."Balance" > 0 and o."ReceivedAtShop" is not true
                            and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled', 'delivered', 'shipped', 'new')),
    'vendor_payables', (select greatest(ap, 0) from vendor_ap),
    'vendor_overdue', (select coalesce(sum(open_amount), 0) from open_vendor_bills
                       where open_amount > 0 and "DueDate" < v_today),
    'bills_overdue_amount', (select coalesce(sum("ExpectedAmount"), 0) from bill_unpaid where due_date < v_today),
    'bills_overdue_count', (select count(*) from bill_unpaid where due_date < v_today),
    'bills_due30_amount', (select coalesce(sum("ExpectedAmount"), 0) from bill_unpaid where due_date >= v_today),
    'bills_due30_count', (select count(*) from bill_unpaid where due_date >= v_today),
    'owed_to_owner', public._owner_loan_outstanding(),
    'customer_deposits', (select coalesce(sum(deposit), 0) from adv where deposit > 0),
    'customer_deposits_count', (select count(*) from adv where deposit > 0),
    'capital_total', (select coalesce(sum("Amount"), 0) from public."OwnerFundEntries"
                      where not "IsVoid" and "EntryType" = 'Capital In'),
    'drawings_total', (select coalesce(sum("Amount"), 0) from public."OwnerFundEntries"
                       where not "IsVoid" and "EntryType" = 'Drawing')
  ) into v_position;

  select jsonb_build_object(
    'capital_in', coalesce(sum("Amount") filter (where "EntryType" = 'Capital In'), 0),
    'owner_loan', coalesce(sum("Amount") filter (where "EntryType" = 'Owner Loan'), 0),
    'paid_directly', coalesce(sum("Amount") filter (where "Method" = 'Paid Directly'), 0),
    'drawings', coalesce(sum("Amount") filter (where "EntryType" = 'Drawing'), 0),
    'repayments', coalesce(sum("Amount") filter (where "EntryType" = 'Loan Repayment'), 0),
    'entries', count(*)
  ) into v_owner
  from public."OwnerFundEntries"
  where not "IsVoid" and "EntryDate" >= p_from and "EntryDate" <= p_to;

  select jsonb_build_object(
    'purchases', (select coalesce(sum(round(coalesce(l."UnitCost", 0) * coalesce(l."QtyReceived", 0), 2)), 0)
                  from public."PostedPurchaseOrderLines" l
                  join public."PostedPurchaseOrders" h on h."PONo" = l."PONo"
                  where (h."PostedAtUtc" at time zone 'Asia/Manila')::date between p_from and p_to),
    'vendor_payments', (select coalesce(sum(p."Amount"), 0) from public."VendorPayments" p
                        where not p."IsVoid" and p."PaymentDate" between p_from and p_to),
    'bills_paid_business', (select coalesce(sum(p."Amount"), 0) from public."BusinessBillPayments" p
                            where not p."IsVoid" and p."PaidBy" = 'Business' and p."PaidDate" between p_from and p_to),
    'bills_paid_owner', (select coalesce(sum(p."Amount"), 0) from public."BusinessBillPayments" p
                         where not p."IsVoid" and p."PaidBy" <> 'Business' and p."PaidDate" between p_from and p_to)
  ) into v_cash;

  with items as (
    select 'Bill'::text as kind, b."Name"::text as name, d.due_date, b."ExpectedAmount" as amount
    from public."BusinessBills" b
    cross join lateral public._business_bill_due_dates(b."FirstDueDate", b."Frequency", b."FirstDueDate", v_today + 30) d
    where b."IsActive"
      and not exists (select 1 from public."BusinessBillPayments" p
                      where p."BillID" = b."BillID" and p."DueDate" = d.due_date and not p."IsVoid")
    union all
    select 'Vendor', coalesce(v."Name", b."VendorCode")::text || ' · ' || b."BillNo", b."DueDate",
           b."Amount" - coalesce((select sum(p."Amount") from public."VendorPayments" p
                                  where p."BillNo" = b."BillNo" and not p."IsVoid"), 0)
    from public."VendorBills" b
    left join public."Vendors" v on v."VendorCode" = b."VendorCode"
    where not b."IsVoid" and b."DueDate" is not null and b."DueDate" <= v_today + 30
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'name', name, 'due_date', due_date, 'amount', amount)
                            order by due_date, name), '[]'::jsonb)
  into v_upcoming
  from (select * from items where kind = 'Bill' or amount > 0 order by due_date, name limit 25) t;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'today', v_today,
    'pnl', public._my_view_pnl(p_from, p_to),
    'prev', public._my_view_pnl(p_from - v_days, p_from - 1),
    'trend', coalesce(v_trend, '[]'::jsonb),
    'position', v_position,
    'owner', v_owner,
    'cash_out', v_cash,
    'upcoming', v_upcoming
  );
end;
$$;

grant execute on function public.admin_get_my_view(text, text, date, date) to anon;

notify pgrst, 'reload schema';

-- ============================================================================
-- Verification - ONE result: OK / FIX per item, plus how many orders are voided so far.
-- ============================================================================
with fn as (
  select p.proname, pg_get_functiondef(p.oid) as def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
  where p.proname in ('_advance_order_prod_status', '_ile_reconcile_advance_order', '_serial_order_is_open',
                      'staff_get_advance_orders_to_follow', 'admin_list_deliverable_online_orders',
                      'admin_get_dashboard_daily_advance_orders',
                      'admin_get_my_view', 'pos_check_advance_order_void', 'staff_get_advance_order_voids',
                      '_advance_order_can_request_transfer', '_serial_order_is_fulfilled')
)
select 'column AdvanceOrders.IsVoid' as check_name,
       case when exists (select 1 from information_schema.columns where table_schema = 'public'
                         and table_name = 'AdvanceOrders' and column_name = 'IsVoid') then 'OK' else 'FIX' end as result
union all
select 'column AdvanceOrderProduction.VoidedAtUtc',
       case when exists (select 1 from information_schema.columns where table_schema = 'public'
                         and table_name = 'AdvanceOrderProduction' and column_name = 'VoidedAtUtc') then 'OK' else 'FIX' end
union all
select 'trigger ' || t.name,
       case when exists (select 1 from pg_trigger where tgname = t.name and not tgisinternal) then 'OK' else 'FIX' end
from (values ('TR_AdvanceOrders_Void'), ('TR_AdvanceOrderProduction_VoidGuard'),
             ('TR_DeliveryStops_VoidGuard'), ('TR_Transfer_Line_VoidGuard')) t(name)
union all
select 'function ' || f.name || ' knows voided orders',
       case when exists (select 1 from fn where fn.proname = f.name and fn.def ilike '%' || f.marker || '%') then 'OK'
            else 'FIX (missing or an older copy - re-run this file)' end
from (values ('_advance_order_prod_status', '''Voided'''), ('_ile_reconcile_advance_order', 'is_void'),
             ('_serial_order_is_open', 'IsVoid'), ('staff_get_advance_orders_to_follow', '''Voided'''),
             ('admin_list_deliverable_online_orders', 'IsVoid'), ('admin_get_dashboard_daily_advance_orders', 'IsVoid'),
             ('admin_get_my_view', 'IsVoid'),
             ('pos_check_advance_order_void', 'only orders from today or yesterday'), ('staff_get_advance_order_voids', 'IsVoid'),
             ('_advance_order_can_request_transfer', '_advance_order_is_void'), ('_serial_order_is_fulfilled', 'VoidedAtUtc')) f(name, marker)
union all
select 'POS key can call pos_check_advance_order_void',
       case when has_function_privilege('anon', 'public.pos_check_advance_order_void(text)', 'execute') then 'OK' else 'FIX' end
union all
select 'voided advance orders so far (info)',
       (select count(*) from public."AdvanceOrders" where "IsVoid")::text
       || ' (' || (select count(*) from public."AdvanceOrderVoids" where "Errors" is not null)::text || ' with errors)';
