-- Serials reserved for an order - per "when serials has been made to the order it is not tagging for
-- that order right? ... another customer walk in then grab that serials since its available.. so i ended
-- up losing serials for order 1" / "yes show it as reserved so they are aware that this is reserved.
-- lets do across all orders".
--
-- Before: a Production Order built FOR an order (Online Orders "Assign - build missing units" / Request
-- Production -> ProductionOrders.SourceOnlineOrderId) posted its output serials as plain IN_STOCK. Every
-- picker (POS walk-in sale, POS Pay In Full, portal Ready to Ship of OTHER orders, Transfer Orders) could
-- take them, and the order they were built for came up short at Ready to Ship.
--
-- Now a serial can be RESERVED for one order:
--   ItemSerialTracking."Status" = 'RESERVED' + "ReservedForOrderId" = the order's link - the same value
--   SoldOnlineOrderId gets when it ships: the OrderID for Online / Walk-in orders, 'ADV-' || TransactionNo
--   for Advance Orders. "ReservedAtUtc" / "ReservedBy" say when / who. The columns are only meaningful
--   while Status = 'RESERVED' (every check below tests both).
--
--   * Automatic: Production Output of a Production Order linked to an order (SourceOnlineOrderId) creates
--     its serials RESERVED for that order, while the order is still open (AFTER INSERT trigger on
--     ProductionOrderOutputSerials - staff_post_production_output itself is unchanged).
--   * By hand (any order type): staff_reserve_serials_for_order - Serial Tracker > Reserve for Order.
--     Released by staff_release_serial_reservations (Serial Tracker > Release Reservation) - Super User,
--     Production Manager or Serial Admin only, since that hands the unit back to walk-in sales.
--   * Not pickable by anyone else: every picker only offers IN_STOCK - the desktop POS included
--     (ProductSerialTrackingForm.GetAvailableSerials), so no POS update is needed. The POS pulls the new
--     status by UpdatedAtUtc like any other serial change.
--   * Ready to Ship of THAT order: the picker pre-fills its reserved serials (docs/js/onlineOrders.js) and
--     admin_update_online_order_status / staff_advance_order_to_ship_with_serials claim a serial that is
--     IN_STOCK *or* RESERVED for this order. Any reservation of the order NOT used (staff picked other
--     units) goes back to IN_STOCK once it ships.
--   * Walk-in orders (no Ready to Ship - they're Shipped in Pancake from the start): Mark Picked Up turns
--     the order's reserved serials SOLD to it.
--   * Online / Walk-in order cancelled -> its reservations go back to IN_STOCK. Advance orders have no
--     cancel status (AdvanceOrders has no Status column) - only a deleted advance order frees them;
--     otherwise Release Reservation in the Serial Tracker.
--   * Shown as reserved: Serial Tracker (Reserved tab + "Reserved for" in the Sold To column / card),
--     order Serials FactBoxes (badge), Stock FactBox ("n reserved"), the online order stock check
--     ("x/y in stock (n reserved for this order)" - an order's own reserved units count as its stock).
--   * Still ON HAND for counting: the Item Ledger is untouched by a reservation, and the Serial Inventory
--     Journal / output reversal treat RESERVED like IN_STOCK - supabase_serial_reservation_on_hand.sql.
--
-- Re-creates (latest versions + the reservation change, nothing else):
--   admin_update_online_order_status        (supabase_online_order_to_ship_production_gate.sql)
--   staff_advance_order_to_ship_with_serials (supabase_advance_order_serials.sql)
--   staff_get_online_order_stock_status      (supabase_online_order_stock_status_set.sql) + 'reserved'
--   staff_get_lines_stock_by_warehouse / staff_get_document_stock_by_warehouse + reserved column
--   staff_get_online_order_serial_labels / staff_get_advance_order_serial_labels + status column
--   staff_search_item_serial_tracking        (supabase_serial_tracker_sort_latest_update.sql) + reserved_*
--   admin_bulk_set_serial_status             (supabase_serial_bulk_floating.sql) - won't float a reserved unit
-- Don't re-run those older files afterwards - they'd drop the reservation handling again.
--
-- Run AFTER all of the files above (all live already). Safe to re-run. Then run
-- supabase_serial_reservation_on_hand.sql, then supabase_serial_reservation_backfill.sql.

-- ============================================================================
-- 1. Columns
-- ============================================================================

alter table public."ItemSerialTracking" add column if not exists "ReservedForOrderId" varchar(100);
alter table public."ItemSerialTracking" add column if not exists "ReservedAtUtc" timestamptz;
alter table public."ItemSerialTracking" add column if not exists "ReservedBy" varchar(100);

create index if not exists "IX_ItemSerialTracking_ReservedForOrderId"
  on public."ItemSerialTracking" ("ReservedForOrderId") where "Status" = 'RESERVED';

comment on column public."ItemSerialTracking"."ReservedForOrderId" is
  'While Status = RESERVED: the order the unit is held for (OrderID, or ADV-<TransactionNo>). supabase_serial_order_reservation.sql.';

-- ============================================================================
-- 2. Helpers
-- ============================================================================

-- The link a serial carries for an order: p_doc_type 'online' (Online / Walk-in) or 'advance'.
create or replace function public._serial_order_link(p_doc_type text, p_doc_no text)
returns text
language sql
immutable
as $$
  select case lower(trim(coalesce(p_doc_type, '')))
    when 'advance' then 'ADV-' || regexp_replace(trim(coalesce(p_doc_no, '')), '^ADV-', '', 'i')
    when 'online' then nullif(trim(coalesce(p_doc_no, '')), '')
  end;
$$;

-- Still waiting for its units: not cancelled, not shipped / picked up yet.
create or replace function public._serial_order_is_open(p_link text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    -- AdvanceOrders has no cancel status - open = still there and not Shipped.
    when p_link ilike 'ADV-%' then exists (
      select 1 from public."AdvanceOrders" a
      where a."TransactionNo" = substr(p_link, 5)
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

-- Super User, Production Manager or Serial Admin.
create or replace function public._serial_can_manage_reservations(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public."StaffUsers"
    where "Username" = p_username and "IsActive"
      and ("SuperUser" or coalesce("SerialAdmin", false)
           or 'ProductionManager' = any(coalesce("StaffRoles", '{}')))
  );
$$;

revoke execute on function public._serial_can_manage_reservations(text) from public, anon, authenticated;

-- Puts an order's reservations back In Stock (cancelled order / order shipped with other units).
create or replace function public._serial_release_order_reservations(p_link text, p_by text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  update public."ItemSerialTracking"
     set "Status" = 'IN_STOCK', "UpdatedAtUtc" = now(), "UpdatedBy" = left(coalesce(p_by, 'system'), 100)
   where "Status" = 'RESERVED' and "ReservedForOrderId" = p_link;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public._serial_release_order_reservations(text, text) from public, anon, authenticated;

-- ============================================================================
-- 3. Automatic: output of a Production Order built for an order
-- ============================================================================

create or replace function public._serial_reserve_on_output()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_link text;
  v_by text;
begin
  select nullif(trim(po."SourceOnlineOrderId"), ''), o."PostedBy"
    into v_link, v_by
  from public."ProductionOrderOutputs" o
  join public."ProductionOrders" po on po."No" = o."ProdOrderNo"
  where o."EntryNo" = new."EntryNo";

  if v_link is null or not public._serial_order_is_open(v_link) then
    return new;
  end if;

  -- UpdatedAtUtc so the desktop POS pulls the RESERVED status down (and stops offering the unit).
  update public."ItemSerialTracking"
     set "Status" = 'RESERVED', "ReservedForOrderId" = v_link, "ReservedAtUtc" = now(),
         "ReservedBy" = left(coalesce(v_by, 'production output'), 100),
         "UpdatedAtUtc" = now(), "UpdatedBy" = left(coalesce(v_by, "UpdatedBy"), 100)
   where "RunningSerialNo" = new."RunningSerialNo" and "Status" = 'IN_STOCK';
  return new;
end;
$$;

drop trigger if exists "TR_ProductionOrderOutputSerials_Reserve" on public."ProductionOrderOutputSerials";
create trigger "TR_ProductionOrderOutputSerials_Reserve"
  after insert on public."ProductionOrderOutputSerials"
  for each row execute function public._serial_reserve_on_output();

-- ============================================================================
-- 4. By hand: reserve / release (Serial Tracker)
-- ============================================================================

drop function if exists public.staff_reserve_serials_for_order(text, text, text, text, text[]);

-- p_doc_type 'online' (Online / Walk-in order ID) or 'advance' (TransactionNo). Only In Stock serials;
-- staff outside production / Serial Admin only at their own warehouse.
create or replace function public.staff_reserve_serials_for_order(
  p_admin_username text,
  p_admin_password text,
  p_doc_type text,
  p_doc_no text,
  p_serial_nos text[]
)
returns table(serial_no text, changed boolean, reason text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_link text := public._serial_order_link(p_doc_type, p_doc_no);
  v_manager boolean;
  v_staff_warehouse text;
  v_sn text;
  v_row public."ItemSerialTracking";
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_link is null or v_link = 'ADV-' then
    raise exception 'Enter the order no. to reserve for.';
  end if;
  if v_link ilike 'ADV-%' then
    if not exists (select 1 from public."AdvanceOrders" a where a."TransactionNo" = substr(v_link, 5)) then
      raise exception 'Advance order % not found.', substr(v_link, 5);
    end if;
  elsif not exists (select 1 from public."OnlineOrders" o where o."OrderID" = v_link) then
    raise exception 'Order % not found in Online / Walk-in Orders.', v_link;
  end if;
  if not public._serial_order_is_open(v_link) then
    raise exception 'Order % is already cancelled, shipped or picked up - nothing to reserve for.', p_doc_no;
  end if;

  v_manager := public._serial_can_manage_reservations(p_admin_username);
  select nullif(trim(s."WarehouseName"), '') into v_staff_warehouse
  from public."StaffUsers" s where s."Username" = p_admin_username;

  foreach v_sn in array coalesce(p_serial_nos, '{}') loop
    serial_no := v_sn;
    select * into v_row from public."ItemSerialTracking" s where s."SerialNo" = v_sn for update;
    if not found then
      changed := false; reason := 'not found';
    elsif v_row."Status" = 'RESERVED' and v_row."ReservedForOrderId" = v_link then
      changed := false; reason := 'already reserved for this order';
    elsif v_row."Status" = 'RESERVED' then
      changed := false; reason := 'reserved for order ' || coalesce(v_row."ReservedForOrderId", '?') || ' - release it first';
    elsif v_row."Status" <> 'IN_STOCK' then
      changed := false; reason := 'not In Stock (' || coalesce(v_row."Status", '-') || ')';
    elsif not v_manager and v_staff_warehouse is not null
          and lower(trim(coalesce(v_row."Location", ''))) <> lower(v_staff_warehouse) then
      changed := false; reason := 'at ' || coalesce(v_row."Location", 'no location') || ', not your warehouse';
    else
      update public."ItemSerialTracking"
         set "Status" = 'RESERVED', "ReservedForOrderId" = v_link, "ReservedAtUtc" = now(),
             "ReservedBy" = p_admin_username, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
       where "RunningSerialNo" = v_row."RunningSerialNo";
      changed := true; reason := null;
    end if;
    return next;
  end loop;
end;
$$;

grant execute on function public.staff_reserve_serials_for_order(text, text, text, text, text[]) to anon;

drop function if exists public.staff_release_serial_reservations(text, text, text[]);

create or replace function public.staff_release_serial_reservations(
  p_admin_username text,
  p_admin_password text,
  p_serial_nos text[]
)
returns table(serial_no text, changed boolean, reason text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_sn text;
  v_status text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._serial_can_manage_reservations(p_admin_username) then
    raise exception 'Only a Super User, Production Manager or Serial Admin can release a reservation.';
  end if;

  foreach v_sn in array coalesce(p_serial_nos, '{}') loop
    serial_no := v_sn;
    select s."Status" into v_status from public."ItemSerialTracking" s where s."SerialNo" = v_sn for update;
    if not found then
      changed := false; reason := 'not found';
    elsif v_status <> 'RESERVED' then
      changed := false; reason := 'not reserved (' || coalesce(v_status, '-') || ')';
    else
      update public."ItemSerialTracking"
         set "Status" = 'IN_STOCK', "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
       where "SerialNo" = v_sn;
      changed := true; reason := null;
    end if;
    return next;
  end loop;
end;
$$;

grant execute on function public.staff_release_serial_reservations(text, text, text[]) to anon;

-- ============================================================================
-- 5. Order events: cancelled -> release; walk-in picked up -> SOLD to it
-- ============================================================================

create or replace function public._serial_reservation_on_online_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if lower(trim(coalesce(new."Status", ''))) in ('canceled', 'cancelled')
     and lower(trim(coalesce(old."Status", ''))) not in ('canceled', 'cancelled') then
    perform public._serial_release_order_reservations(new."OrderID", 'order cancelled');
  elsif new."ReceivedAtShop" is true and new."PickedUpAtUtc" is not null and old."PickedUpAtUtc" is null then
    update public."ItemSerialTracking"
       set "Status" = 'SOLD', "SoldOnlineOrderId" = new."OrderID", "UpdatedAtUtc" = now(),
           "UpdatedBy" = left(coalesce("ReservedBy", 'walk-in picked up'), 100)
     where "Status" = 'RESERVED' and "ReservedForOrderId" = new."OrderID";
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_OnlineOrders_SerialReservation" on public."OnlineOrders";
create trigger "TR_OnlineOrders_SerialReservation"
  after update of "Status", "PickedUpAtUtc" on public."OnlineOrders"
  for each row execute function public._serial_reservation_on_online_order();

-- AdvanceOrders has no cancel status; an advance order that's removed frees its reservations.
create or replace function public._serial_reservation_on_advance_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._serial_release_order_reservations('ADV-' || old."TransactionNo", 'advance order removed');
  return old;
end;
$$;

drop trigger if exists "TR_AdvanceOrders_SerialReservation" on public."AdvanceOrders";
create trigger "TR_AdvanceOrders_SerialReservation"
  after delete on public."AdvanceOrders"
  for each row execute function public._serial_reservation_on_advance_order();

-- ============================================================================
-- 6. Ready to Ship claims the order's own reservations
-- ============================================================================

-- Online / Walk-in: supabase_online_order_to_ship_production_gate.sql's version plus (a) the claim also
-- takes a serial RESERVED for this order, (b) after To Ship the order's unused reservations go back In Stock.
create or replace function public.admin_update_online_order_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_new_status text,
  p_notify_customer boolean default false,
  p_serial_running_nos bigint[] default null,
  -- New serials to create for units with no In Stock serial (supabase_online_order_ship_new_serials.sql):
  -- [{"item_code": "...", "variation_id": "...", "description": "...", "quantity": 1}, ...]
  p_new_serials jsonb default null
)
returns table(new_status text, message_sent boolean, message_error text, created_serials jsonb,
              gma_psid text, gma_message text)
language plpgsql
security definer
set search_path = public, extensions
-- Overrides whatever statement_timeout the authenticator role happens to have (previously seen
-- hitting Postgres's default ~8s and killing this mid-flight - "canceling statement due to
-- statement timeout" - since this chains a GET + PATCH + PATCH, each with its own retry). Set
-- directly on the function so it's guaranteed regardless of role/session config.
set statement_timeout = '60000'
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_order_url text;
  v_current_status text;
  v_api_token text;
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_patch_response extensions.http_response;
  v_message_sent boolean := false;
  v_message_error text;
  v_requested_serial_count int;
  v_claimed_serial_count int;
  v_patch_attempt int;
  v_req record;
  v_needed int;
  v_have int;
  v_location text;
  v_serial text;
  v_created jsonb := '[]'::jsonb;
  v_gma_psid text;
  v_gma_message text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "Status" into v_current_status from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    raise exception 'Order % not found.', p_order_id;
  end if;

  if lower(trim(coalesce(v_current_status, ''))) = 'new' then
    raise exception 'Cannot change status for orders with status ''new'' - please ask the online sales team to confirm the order first.';
  end if;

  if lower(trim(p_new_status)) <> 'to ship' then
    raise exception 'You can only change status to ''To Ship'' from here.';
  end if;

  -- Mirrors OnlineOrdersForm.cs's IsPrintedStatusForRow gate on MarkRowAsToShipAsync - the desktop
  -- app already refuses to mark an order 'To Ship' unless it's currently 'Printed' ("Update not
  -- allowed status is not \"printed\""), so this portal RPC needs the same guard, not just the
  -- 'new' check above - otherwise a Confirmed-but-not-yet-printed order could be jumped straight
  -- to To Ship from here even though the desktop app would block it.
  -- 'Assigned' (supabase_online_order_assigned_status.sql) is a Printed order whose makers are set,
  -- so it can go To Ship too.
  if lower(trim(coalesce(v_current_status, ''))) not in ('printed', 'assigned') then
    raise exception 'Cannot mark as To Ship - this order''s status is not ''Printed'' yet. Print the order first.';
  end if;

  -- Custom order still in production (supabase_online_order_to_ship_production_gate.sql): hard stop.
  if public._online_order_to_ship_production_block(p_order_id) is not null then
    raise exception '%', public._online_order_to_ship_production_block(p_order_id);
  end if;

  -- Mirrors OnlineOrdersForm.cs's EnsureOrderSerialTrackingAsync, which the desktop's own To Ship
  -- action runs before changing status: a production warehouse can't ship a serial-tracked item
  -- (e.g. a custom aquarium) without a physical unit's serial tied to the order. The portal's
  -- picker (docs/js/onlineOrders.js) only ever offers EXISTING IN_STOCK serials, never generates
  -- new ones (per direct instruction - unlike the desktop, which can auto-create + print labels),
  -- so p_serial_running_nos is only ever populated when every required line was fully covered by
  -- available stock; the caller blocks Ship client-side otherwise and tells staff to finish on the
  -- desktop app instead. Claiming BEFORE the Pancake calls below means if the Pancake PATCH fails
  -- later and this function raises, Postgres rolls back this UPDATE too (same implicit-transaction
  -- semantics as everything else in a single SECURITY DEFINER call) - so a failed attempt never
  -- leaves serials claimed against an order that's still sitting at 'Printed' in Pancake.
  if p_serial_running_nos is not null and array_length(p_serial_running_nos, 1) > 0 then
    v_requested_serial_count := array_length(p_serial_running_nos, 1);

    with claimed as (
      update public."ItemSerialTracking"
        set "Status" = 'SOLD',
            "SoldOnlineOrderId" = p_order_id,
            "UpdatedAtUtc" = now()
        where "RunningSerialNo" = any(p_serial_running_nos)
          -- supabase_serial_order_reservation.sql: or held for THIS order
          and ("Status" = 'IN_STOCK' or ("Status" = 'RESERVED' and "ReservedForOrderId" = p_order_id))
        returning "RunningSerialNo"
    )
    select count(*) into v_claimed_serial_count from claimed;

    if v_claimed_serial_count < v_requested_serial_count then
      raise exception 'Only % of % selected serial(s) were still available - someone may have just claimed one. Refresh and try again.', v_claimed_serial_count, v_requested_serial_count;
    end if;
  end if;

  -- Create new serials for units with no In Stock serial - per "is it possible to move the printout of
  -- serials" / "at ready to ship". Same as the desktop's To Ship (EnsureOrderSerialTrackingAsync ->
  -- CreateSoldSerialRecords): numbered RS-<ItemCode>-<YY>-<000001> (_production_next_serial_no, one
  -- counter per item), created already SOLD to this order at the caller's warehouse. Only for this
  -- order's serial-tracked lines and never more than a line still needs (picked serials count). Part of
  -- this call's transaction, so a failed Pancake update below rolls these back too.
  if p_new_serials is not null and jsonb_typeof(p_new_serials) = 'array' and jsonb_array_length(p_new_serials) > 0 then
    select coalesce(
      (select nullif(trim(s."WarehouseName"), '') from public."StaffUsers" s where s."Username" = p_admin_username),
      (select w."Name" from public."OnlineOrders" o join public."Warehouses" w on w."ID" = o."LocationID" where o."OrderID" = p_order_id)
    ) into v_location;

    for v_req in
      select * from jsonb_to_recordset(p_new_serials) as x(item_code text, variation_id text, description text, quantity int)
    loop
      select coalesce(sum(r.quantity_needed), 0) into v_needed
      from public.admin_get_online_order_serial_requirements(p_admin_username, p_admin_password, p_order_id) r
      where r.item_code = v_req.item_code and coalesce(r.variation_id, '') = coalesce(v_req.variation_id, '');

      select count(*) into v_have
      from public."ItemSerialTracking" s
      where s."SoldOnlineOrderId" = p_order_id and s."Status" = 'SOLD'
        and s."ItemCode" = v_req.item_code and coalesce(s."VariantCode", '') = coalesce(v_req.variation_id, '');

      if coalesce(v_req.quantity, 0) < 1 or v_have + v_req.quantity > v_needed then
        raise exception 'Can''t create % new serial(s) for % - this order needs % and % already have a serial.',
          coalesce(v_req.quantity, 0), v_req.item_code, v_needed, v_have;
      end if;

      for i in 1..v_req.quantity loop
        v_serial := public._production_next_serial_no(v_req.item_code);
        -- UpdatedAtUtc set so the desktop POS pulls it down (SyncItemSerialTrackingFromSupabaseAsync).
        insert into public."ItemSerialTracking"
          ("SerialNo", "ItemCode", "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedBy",
           "VariantCode", "SoldOnlineOrderId", "UpdatedAtUtc", "UpdatedBy")
        values
          (v_serial, v_req.item_code, left(coalesce(nullif(trim(v_req.description), ''), v_req.item_code), 255), v_location, 'SOLD', p_order_id, p_admin_username,
           nullif(trim(coalesce(v_req.variation_id, '')), ''), p_order_id, now(), p_admin_username);
        v_created := v_created || jsonb_build_array(jsonb_build_object(
          'serial_no', v_serial, 'item_code', v_req.item_code,
          'description', coalesce(nullif(trim(v_req.description), ''), v_req.item_code)));
      end loop;
    end loop;
  end if;

  v_api_token := '8'; -- MapStatusForApi's token for 'To Ship'

  -- Pancake PATCH (bank_payments snapshot/restore + up to 3 tries with pauses on a dropped connection
  -- such as "OpenSSL SSL_read: SSL_ERROR_SYSCALL") - shared helper, supabase_pancake_patch_retry.sql.
  -- Raises if Pancake can't be reached, which rolls back the serial claim above too.
  perform public._pancake_patch_online_order_status(p_order_id, jsonb_build_object('status', v_api_token));

  -- Reflects immediately in the portal without waiting for the next cron sync pass - harmless even
  -- though OnlineOrders is normally a Pancake -> Supabase mirror, since this is exactly the value
  -- Pancake now actually has.
  update public."OnlineOrders" set "Status" = p_new_status where "OrderID" = p_order_id;

  -- supabase_serial_order_reservation.sql: shipped with other units - the order's leftover
  -- reservations are free for anyone again.
  perform public._serial_release_order_reservations(p_order_id, p_admin_username);

  if p_notify_customer then
    v_gma_psid := public._online_order_gma_psid(p_order_id);
    if v_gma_psid is not null then
      -- GMA Page order: the client sends it via chatbot-staff-reply (supabase_online_order_status_message_gma.sql).
      v_gma_message := public._online_order_status_message_text(p_order_id, p_new_status);
    else
      begin
        perform public._send_online_order_status_message(p_order_id, p_new_status);
        v_message_sent := true;
      exception when others then
        v_message_error := sqlerrm;
      end;
    end if;
  end if;

  return query select p_new_status, v_message_sent, v_message_error, v_created, v_gma_psid, v_gma_message;
end;
$$;

grant execute on function public.admin_update_online_order_status(text, text, text, text, boolean, bigint[], jsonb) to anon;

-- Advance: supabase_advance_order_serials.sql's version plus the same two changes.
create or replace function public.staff_advance_order_to_ship_with_serials(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_serial_running_nos bigint[] default null,
  -- [{"item_code": "...", "variation_id": "...", "description": "...", "quantity": 1}, ...]
  p_new_serials jsonb default null
)
returns table(new_status text, created_serials jsonb)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '50000'
as $$
declare
  v_link text := 'ADV-' || p_no;
  v_receipt text;
  v_order_warehouse text;
  v_is_super boolean;
  v_staff_warehouse text;
  v_staff_is_production boolean;
  v_location text;
  v_picks bigint[] := coalesce(p_serial_running_nos, '{}');
  v_has_new boolean := p_new_serials is not null and jsonb_typeof(p_new_serials) = 'array' and jsonb_array_length(p_new_serials) > 0;
  v_bad text;
  v_claimed int;
  v_req record;
  v_serial text;
  v_created jsonb := '[]'::jsonb;
  v_status text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can change this.';
  end if;

  select nullif(trim(a."ReceiptNo"), ''), nullif(trim(a."Warehouse"), '')
    into v_receipt, v_order_warehouse
  from public."AdvanceOrders" a where a."TransactionNo" = p_no;
  if not found then
    raise exception 'Advance order % not found.', p_no;
  end if;

  if array_length(v_picks, 1) > 0 or v_has_new then
    -- Every requested unit must belong to a serial-tracked line that still needs one: picks + new per
    -- item/variant never more than "still to tag".
    create temp table if not exists _adv_serial_req (item_code text, variation_id text, description text, quantity_needed int) on commit drop;
    truncate _adv_serial_req;
    insert into _adv_serial_req
      select r.item_code, r.variation_id, r.description, r.quantity_needed
      from public.staff_get_advance_order_serial_requirements(p_admin_username, p_admin_password, p_no) r;

    select string_agg(coalesce(s."SerialNo", x.n::text), ', ') into v_bad
    from unnest(v_picks) x(n)
    left join public."ItemSerialTracking" s on s."RunningSerialNo" = x.n
    where s."RunningSerialNo" is null
       or not exists (select 1 from _adv_serial_req r
                      where r.item_code = s."ItemCode" and coalesce(r.variation_id, '') = coalesce(s."VariantCode", ''));
    if v_bad is not null then
      raise exception 'Serial(s) % don''t match any item on advance order % that needs a serial.', v_bad, p_no;
    end if;

    -- Picked serials must be at the order's own branch (AdvanceOrders."Warehouse") - same as the picker.
    if v_order_warehouse is not null then
      select string_agg(s."SerialNo" || ' (at ' || coalesce(nullif(trim(s."Location"), ''), 'no location') || ')', ', ') into v_bad
      from public."ItemSerialTracking" s
      where s."RunningSerialNo" = any(v_picks)
        and lower(coalesce(trim(s."Location"), '')) <> lower(v_order_warehouse);
      if v_bad is not null then
        raise exception 'Serial(s) % aren''t at %, the branch of advance order %.', v_bad, v_order_warehouse, p_no;
      end if;
    end if;

    select string_agg(r.item_code || ' (needs ' || r.quantity_needed || ', got ' || (coalesce(p.n, 0) + coalesce(nw.n, 0)) || ')', ', ')
      into v_bad
    from _adv_serial_req r
    left join (
      select s."ItemCode" as item_code, coalesce(s."VariantCode", '') as variant, count(*)::int as n
      from public."ItemSerialTracking" s where s."RunningSerialNo" = any(v_picks)
      group by 1, 2
    ) p on p.item_code = r.item_code and p.variant = coalesce(r.variation_id, '')
    left join (
      select x.item_code, coalesce(x.variation_id, '') as variant, sum(coalesce(x.quantity, 0))::int as n
      from jsonb_to_recordset(case when v_has_new then p_new_serials else '[]'::jsonb end)
           as x(item_code text, variation_id text, description text, quantity int)
      group by 1, 2
    ) nw on nw.item_code = r.item_code and nw.variant = coalesce(r.variation_id, '')
    where coalesce(p.n, 0) + coalesce(nw.n, 0) > r.quantity_needed;
    if v_bad is not null then
      raise exception 'Too many serials for advance order %: %.', p_no, v_bad;
    end if;

    if v_has_new and exists (
      select 1 from jsonb_to_recordset(p_new_serials) as x(item_code text, variation_id text, description text, quantity int)
      where coalesce(x.quantity, 0) < 1
         or not exists (select 1 from _adv_serial_req r
                        where r.item_code = x.item_code and coalesce(r.variation_id, '') = coalesce(x.variation_id, ''))) then
      raise exception 'A new serial was requested for an item that isn''t a serial-tracked line on advance order %.', p_no;
    end if;
  end if;

  -- Claim the picked In Stock serials.
  if array_length(v_picks, 1) > 0 then
    with claimed as (
      update public."ItemSerialTracking"
         set "Status" = 'SOLD',
             "SoldOnlineOrderId" = v_link,
             "SoldReceiptNo" = coalesce(v_receipt, "SoldReceiptNo"),
             "UpdatedAtUtc" = now(),
             "UpdatedBy" = p_admin_username
       where "RunningSerialNo" = any(v_picks)
         -- supabase_serial_order_reservation.sql: or held for THIS order
         and ("Status" = 'IN_STOCK' or ("Status" = 'RESERVED' and "ReservedForOrderId" = v_link))
      returning 1
    )
    select count(*) into v_claimed from claimed;
    if v_claimed < array_length(v_picks, 1) then
      raise exception 'Only % of % selected serial(s) were still In Stock - someone may have just used one. Refresh and try again.', v_claimed, array_length(v_picks, 1);
    end if;
  end if;

  -- Create new serials (production only), SOLD to this order, numbered like the desktop.
  if v_has_new then
    select coalesce(s."SuperUser", false), nullif(trim(s."WarehouseName"), '')
      into v_is_super, v_staff_warehouse
    from public."StaffUsers" s where s."Username" = p_admin_username;

    select coalesce(bool_or(coalesce(w."IsProductionWarehouse", false)), false) into v_staff_is_production
    from public."Warehouses" w
    where v_staff_warehouse is not null and w."Name" = v_staff_warehouse;

    if not coalesce(v_is_super, false) and not coalesce(v_staff_is_production, false) then
      raise exception 'Only a production warehouse can create new serials. Pick In Stock serials, or mark it Ready to Ship without them.';
    end if;

    v_location := coalesce(v_staff_warehouse, v_order_warehouse);

    for v_req in
      select * from jsonb_to_recordset(p_new_serials) as x(item_code text, variation_id text, description text, quantity int)
    loop
      for i in 1..v_req.quantity loop
        v_serial := public._production_next_serial_no(v_req.item_code);
        -- UpdatedAtUtc set so the desktop POS pulls it down (SyncItemSerialTrackingFromSupabaseAsync).
        insert into public."ItemSerialTracking"
          ("SerialNo", "ItemCode", "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedBy",
           "VariantCode", "SoldOnlineOrderId", "SoldReceiptNo", "UpdatedAtUtc", "UpdatedBy")
        values
          (v_serial, v_req.item_code, left(coalesce(nullif(trim(v_req.description), ''), v_req.item_code), 255), v_location,
           'SOLD', v_link, p_admin_username,
           nullif(trim(coalesce(v_req.variation_id, '')), ''), v_link, v_receipt, now(), p_admin_username);
        v_created := v_created || jsonb_build_array(jsonb_build_object(
          'serial_no', v_serial, 'item_code', v_req.item_code,
          'description', coalesce(nullif(trim(v_req.description), ''), v_req.item_code)));
      end loop;
    end loop;
  end if;

  -- The stage change itself (raises if production isn't done - which rolls the serials back too).
  v_status := public.staff_set_advance_order_stage(p_admin_username, p_admin_password, p_no, 'To Ship');

  -- supabase_serial_order_reservation.sql: leftover reservations (other units were picked) are freed.
  perform public._serial_release_order_reservations(v_link, p_admin_username);

  return query select v_status, v_created;
end;
$$;

grant execute on function public.staff_advance_order_to_ship_with_serials(text, text, text, bigint[], jsonb) to anon;

-- ============================================================================
-- 7. Online order stock check: the order's own reserved units count as its stock
-- ============================================================================

-- supabase_online_order_stock_status_set.sql's version plus: available = In Stock at the order's branch
-- + RESERVED for this order (anywhere), and each line's 'reserved' (how many of those are reserved).
create or replace function public.staff_get_online_order_stock_status(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, warehouse_name text, has_custom_line boolean, needs_serial boolean,
              all_available boolean, lines jsonb, production_order_no text, production_order_status text,
              has_set_line boolean, set_unmapped boolean, set_pending boolean)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with orders as (
      select o."OrderID"::text as order_id, w."Name"::text as warehouse_name
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where o."OrderID"::text = any(coalesce(p_order_ids, '{}'))
    ),
    resolved as (
      select ord.order_id, ord.warehouse_name,
             nullif(trim(l."VariationId"), '') as variation_id,
             l."Description" as description,
             greatest(1, ceil(coalesce(l."Quantity", 1)))::int as qty,
             public._online_order_line_part(l."Description", l."ItemCode", l."product_display_id") as custom_part,
             coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), ''), nullif(trim(l."ItemCode"), '')) as item_code,
             coalesce(v."CategoryCode", i."CategoryCode") as category_code,
             false as from_set,
             false as choose_variant,
             null::text as main_code,
             false as sealant_any
      from orders ord
      join public."OnlineOrderLines" l on l."OrderID"::text = ord.order_id
      -- ONE row each - a join here counted the line once per match.
      left join lateral (
        select v0."ItemCode", v0."CategoryCode" from public."Variants" v0
        where nullif(trim(l."VariationId"), '') is not null and v0."VariationId" = l."VariationId"
        limit 1
      ) v on true
      left join lateral (
        select i0."Code", i0."CategoryCode" from public."Items" i0
        where i0."Code" = l."ItemCode" or i0."VariationId" = l."ItemCode"
        order by (i0."Code" = l."ItemCode") desc
        limit 1
      ) i on true
      -- The SET line itself is never stock-checked - only its package's parts (set_parts below).
      where upper(public._online_order_line_category(l."VariationId",
              coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), '')))) <> 'SET'
    ),
    -- SET lines and their package (null = not mapped yet). exploded = its materials are already lines.
    set_lines as (
      select ord.order_id, ord.warehouse_name,
             public._resolve_set_package(l."VariationId", coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), ''))) as package_name,
             greatest(1, ceil(coalesce(l."Quantity", 1)))::int as set_qty,
             exists (
               select 1 from public."OnlineOrderLines" m
               where m."OrderID" = l."OrderID"
                 and trim(coalesce(m."Note", '')) = 'SET Material for ' || coalesce(
                   nullif(trim(l."Description"), ''), nullif(trim(l."ItemCode"), ''), nullif(trim(l."VariationId"), ''), 'SET Line ' || l."LineID")
             ) as exploded
      from orders ord
      join public."OnlineOrderLines" l on l."OrderID"::text = ord.order_id
      where l."LineID" not like '%~SETMAT~%'
        and upper(public._online_order_line_category(l."VariationId",
              coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), '')))) = 'SET'
    ),
    -- Parts of the not-yet-exploded SET lines, as the SET dialog would default them.
    set_parts as (
      select p.order_id, p.warehouse_name, p.variation_id, p.description, p.qty,
             null::text as custom_part, p.item_code,
             nullif(public._online_order_line_category(coalesce(p.variation_id, p.category_variation_id), p.item_code), '') as category_code,
             true as from_set, p.choose_variant, p.main_code, p.sealant_any
      from (
        select sl.order_id, sl.warehouse_name,
               -- Sealant part: no colour yet (picked at Ready to Ship) - counted across Black + Clear.
               case when sealant then null else nullif(comp -> 'default' ->> 'variation_id', '') end as variation_id,
               case when sealant then comp ->> 'bom_item_name'
                    else coalesce(comp -> 'default' ->> 'name', comp ->> 'bom_item_name') end as description,
               (comp ->> 'quantity')::numeric::int as qty,
               case when sealant then coalesce(nullif(comp -> 'variants' -> 0 ->> 'item_code', ''), comp ->> 'main_item_code', comp ->> 'bom_item_no')
                    else coalesce(nullif(comp -> 'default' ->> 'item_code', ''), comp ->> 'bom_item_no') end as item_code,
               nullif(comp -> 'variants' -> 0 ->> 'variation_id', '') as category_variation_id,
               not sealant and jsonb_typeof(comp -> 'default') is distinct from 'object' as choose_variant,
               coalesce(comp ->> 'main_item_code', comp ->> 'bom_item_no') as main_code,
               sealant as sealant_any
        from set_lines sl
        cross join lateral jsonb_array_elements(public._set_package_components(sl.package_name, sl.set_qty)) comp
        cross join lateral (select coalesce((comp ->> 'sealant_choice')::boolean, false) as sealant) sc
        where sl.package_name is not null and not sl.exploded
      ) p
      where p.qty > 0
    ),
    -- Black / Clear sealant variants per main product (same rule as the Sealant Sales report).
    sealant_variants as (
      select v."VariationId" as variation_id,
             coalesce(nullif(trim(v."MainItemCode"), ''), v."ItemCode") as main_code,
             coalesce(nullif(trim(v."ItemCode"), ''), v."MainItemCode") as item_code,
             v."SKU" as sku,
             case when (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* 'black' then 'Black' else 'Clear' end as colour
      from public."Variants" v
      where (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* 'sealant'
        and (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* '(black|clear)'
    ),
    all_lines as (
      select * from resolved
      union all
      select * from set_parts
    ),
    stock_lines as (
      select r.order_id, r.warehouse_name, r.item_code, r.variation_id, r.main_code, r.sealant_any,
             min(r.description) as description,
             sum(r.qty)::int as needed, bool_or(r.from_set) as from_set, bool_or(r.choose_variant) as choose_variant
      from all_lines r
      left join public."Categories" c on c."Code" = r.category_code
      where r.custom_part is null
        and r.item_code is not null
        and (upper(r.item_code) like 'AQ-%' or coalesce(c."IsProductionCategory", false))
      group by r.order_id, r.warehouse_name, r.item_code, r.variation_id, r.main_code, r.sealant_any
    ),
    -- supabase_serial_order_reservation.sql: In Stock at the branch, or RESERVED for this order.
    counted as (
      select sl.*,
             (select count(*)::int from public."ItemSerialTracking" s
              where s."Status" = 'RESERVED' and s."ReservedForOrderId" = sl.order_id
                and s."ItemCode" = sl.item_code
                and (sl.sealant_any or sl.choose_variant
                     or coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(sl.variation_id, ''))) as reserved,
             (select count(*)::int from public."ItemSerialTracking" s
              where ((s."Status" = 'IN_STOCK' and s."Location" = sl.warehouse_name)
                     or (s."Status" = 'RESERVED' and s."ReservedForOrderId" = sl.order_id))
                and case
                  -- SET sealant part: a unit of either colour of this product counts.
                  when sl.sealant_any then exists (
                    select 1 from sealant_variants sv
                    where sv.main_code = sl.main_code and sv.variation_id = nullif(trim(s."VariantCode"), ''))
                  -- No default variant picked yet - any variant of the item counts.
                  when sl.choose_variant then s."ItemCode" = sl.item_code
                  else s."ItemCode" = sl.item_code
                       and coalesce(nullif(trim(s."VariantCode"), ''), '') = coalesce(sl.variation_id, '')
                end) as available
      from stock_lines sl
    )
    select ord.order_id,
           ord.warehouse_name,
           exists (select 1 from resolved r where r.order_id = ord.order_id and r.custom_part is not null),
           exists (select 1 from counted c where c.order_id = ord.order_id),
           coalesce(bool_and(c.available >= c.needed) filter (where c.order_id is not null), false),
           coalesce(jsonb_agg(jsonb_build_object(
             'item_code', c.item_code, 'variation_id', c.variation_id, 'description', c.description,
             'needed', c.needed, 'available', c.available, 'reserved', c.reserved,
             'from_set', c.from_set, 'choose_variant', c.choose_variant,
             'sealant_any', c.sealant_any,
             -- Colours to pick from when a short sealant part is built (Assign).
             'sealant_options', case when c.sealant_any then (
               select coalesce(jsonb_agg(jsonb_build_object(
                        'variation_id', sv.variation_id, 'item_code', sv.item_code, 'sku', sv.sku, 'colour', sv.colour)
                      order by sv.colour), '[]'::jsonb)
               from sealant_variants sv where sv.main_code = c.main_code) end,
             'variant_name', case when c.sealant_any then 'Black or Clear sealant' else
               (select coalesce(nullif(trim(v."VariantName"), ''), v."SKU") from public."Variants" v where v."VariationId" = c.variation_id limit 1) end,
             'sku', coalesce(
               (select nullif(trim(v."SKU"), '') from public."Variants" v
                 where v."VariationId" = c.variation_id and nullif(trim(v."SKU"), '') is not null limit 1),
               (select nullif(trim(i."SKU"), '') from public."Items" i
                 where i."Code" = c.item_code and nullif(trim(i."SKU"), '') is not null limit 1),
               c.item_code)
           ) order by c.item_code) filter (where c.order_id is not null), '[]'::jsonb),
           (select po."No"::text from public."ProductionOrders" po
             where po."SourceOnlineOrderId" = ord.order_id
             order by (po."Status" <> 'Finished') desc, po."CreatedAtUtc" desc limit 1),
           (select po."Status"::text from public."ProductionOrders" po
             where po."SourceOnlineOrderId" = ord.order_id
             order by (po."Status" <> 'Finished') desc, po."CreatedAtUtc" desc limit 1),
           exists (select 1 from set_lines sl where sl.order_id = ord.order_id),
           exists (select 1 from set_lines sl where sl.order_id = ord.order_id and sl.package_name is null and not sl.exploded),
           exists (select 1 from set_lines sl where sl.order_id = ord.order_id and not sl.exploded)
    from orders ord
    left join counted c on c.order_id = ord.order_id
    group by ord.order_id, ord.warehouse_name;
end;
$$;

grant execute on function public.staff_get_online_order_stock_status(text, text, text[]) to anon;


-- ============================================================================
-- 8. Stock FactBox: reserved units per warehouse (quantity stays = available to sell)
-- ============================================================================

-- supabase_lines_stock_by_warehouse.sql's version plus a reserved column (RESERVED serials of a
-- serial-counted line at that warehouse - 0 for ledger lines).
drop function if exists public.staff_get_document_stock_by_warehouse(text, text, text, text);
drop function if exists public.staff_get_lines_stock_by_warehouse(text, text, jsonb);

create or replace function public.staff_get_lines_stock_by_warehouse(
  p_admin_username text,
  p_admin_password text,
  p_lines jsonb
)
returns table(line_key text, item_code text, variant_id text, source text,
              warehouse_id text, warehouse_name text, is_stock_warehouse boolean, quantity numeric,
              reserved numeric)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with input as (
      select x->>'key' as k,
             nullif(trim(x->>'item_code'), '') as raw_item,
             nullif(trim(x->>'variant_id'), '') as var
      from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x
    ),
    resolved as (
      select inp.k, inp.var,
             coalesce(nullif(trim(v."ItemCode"), ''), nullif(trim(i."Code"), '')) as item,
             nullif(trim(v."MainItemCode"), '') as main_item
      from input inp
      left join lateral (
        select v0."ItemCode", v0."MainItemCode" from public."Variants" v0
        where inp.var is not null and v0."VariationId" = inp.var
        limit 1
      ) v on true
      left join lateral (
        select i0."Code" from public."Items" i0
        where inp.raw_item is not null and (i0."Code" = inp.raw_item or i0."VariationId" = inp.raw_item)
        order by (i0."Code" = inp.raw_item) desc
        limit 1
      ) i on true
    ),
    lines as (
      select r.k, r.var, r.item,
             upper(trim(coalesce(ic."CategoryCode", mc."CategoryCode", ''))) in ('AQUARIUM', 'STAND', 'SUMP') as by_serial
      from resolved r
      left join public."Items" ic on ic."Code" = r.item
      left join public."Items" mc on mc."Code" = r.main_item
      where r.item is not null
    ),
    -- every item code a line covers: the item itself, plus (no variant picked) its variants' own codes
    line_codes as (
      select l.k, l.item as code from lines l
      union
      select l.k, v."ItemCode" from lines l
      join public."Variants" v on v."MainItemCode" = l.item
      where l.var is null and nullif(trim(v."ItemCode"), '') is not null
    ),
    ledger as (
      select l.k, e."WarehouseId"::text as wid, sum(e."Quantity") as qty, 0::numeric as res
      from lines l
      join line_codes lc on lc.k = l.k
      join public."ItemLedgerEntries" e on e."ItemCode" = lc.code
      where not l.by_serial
        -- a variant is booked either under its own ItemCode (VariantId empty) or under the shared
        -- item with VariantId set (items with 2+ variants, _ile_resolve_stock_key)
        and (l.var is null or coalesce(e."VariantId", '') in ('', l.var))
      group by l.k, e."WarehouseId"
    ),
    serials as (
      select l.k, w."ID"::text as wid,
             count(*) filter (where s."Status" = 'IN_STOCK')::numeric as qty,
             count(*) filter (where s."Status" = 'RESERVED')::numeric as res
      from lines l
      join line_codes lc on lc.k = l.k
      join public."ItemSerialTracking" s
        on s."ItemCode" = lc.code and s."Status" in ('IN_STOCK', 'RESERVED')
       and (l.var is null or coalesce(nullif(trim(s."VariantCode"), ''), '') in ('', l.var))
      join public."Warehouses" w on lower(trim(w."Name")) = lower(trim(s."Location"))
      where l.by_serial
      group by l.k, w."ID"
    ),
    balances as (
      select * from ledger
      union all
      select * from serials
    )
    select l.k, l.item, l.var,
           case when l.by_serial then 'serials' else 'ledger' end,
           w."ID"::text, coalesce(w."Name", w."ID")::text,
           coalesce(w."IsActive", true) and coalesce(w."IsStockWarehouse", false),
           coalesce(b.qty, 0)::numeric,
           coalesce(b.res, 0)::numeric
    from lines l
    cross join public."Warehouses" w
    left join balances b on b.k = l.k and b.wid = w."ID"::text
    where (coalesce(w."IsActive", true) and coalesce(w."IsStockWarehouse", false))
       or coalesce(b.qty, 0) <> 0 or coalesce(b.res, 0) <> 0
    order by l.k, w."Name";
end;
$$;

grant execute on function public.staff_get_lines_stock_by_warehouse(text, text, jsonb) to anon;

-- supabase_document_stock_by_warehouse.sql's version plus the reserved column.
create or replace function public.staff_get_document_stock_by_warehouse(
  p_admin_username text,
  p_admin_password text,
  p_doc_type text,
  p_doc_no text
)
returns table(line_key text, item_code text, variant_id text, label text, doc_warehouse text, source text,
              warehouse_id text, warehouse_name text, is_stock_warehouse boolean, quantity numeric,
              reserved numeric)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with src as (
      select coalesce(nullif(trim(l."ItemCode"::text), ''), nullif(trim(l."product_display_id"::text), '')) as item,
             nullif(trim(l."VariationId"::text), '') as var,
             l."Description"::text as lbl,
             o."LocationID"::text as wh
      from public."OnlineOrderLines" l
      left join public."OnlineOrders" o on o."OrderID"::text = l."OrderID"::text
      where p_doc_type = 'online' and l."OrderID"::text = p_doc_no
      union all
      select l."No"::text, null::text, l."Description"::text, a."Warehouse"::text
      from public."AdvanceOrderLines" l
      left join public."AdvanceOrders" a on a."TransactionNo" = l."TransactionNo"
      where p_doc_type = 'advance' and l."TransactionNo" = p_doc_no
      union all
      select l."Item No."::text, nullif(trim(coalesce(l."Variant ID", '')), ''),
             coalesce(nullif(trim(l."Description"), ''), l."Variant Name")::text, h."From Warehouse ID"::text
      from public."Transfer_Line" l
      left join public."Transfer_Header" h on h."No." = l."Document No."
      where p_doc_type = 'transfer' and l."Document No." = p_doc_no
      union all
      select l."ItemCode"::text, nullif(trim(coalesce(l."VariantCode", '')), ''),
             coalesce(nullif(trim(l."Description"), ''), l."ItemName")::text, l."WarehouseId"::text
      from public."PurchaseOrderLines" l
      where p_doc_type = 'purchase' and l."PONo" = p_doc_no
    ),
    -- one entry per item + variant + warehouse (the same item on two lines is shown once)
    keyed as (
      select (row_number() over (order by min(s.lbl)))::text as k, s.item, s.var, min(s.lbl) as lbl, s.wh
      from src s
      where s.item is not null
      group by s.item, s.var, s.wh
    )
    select k.k, st.item_code, st.variant_id, k.lbl, k.wh, st.source,
           st.warehouse_id, st.warehouse_name, st.is_stock_warehouse, st.quantity, st.reserved
    from keyed k
    join public.staff_get_lines_stock_by_warehouse(
           p_admin_username, p_admin_password,
           (select coalesce(jsonb_agg(jsonb_build_object('key', k2.k, 'item_code', k2.item, 'variant_id', k2.var)), '[]'::jsonb)
            from keyed k2)
         ) st on st.line_key = k.k
    order by k.k::int, st.warehouse_name;
end;
$$;

grant execute on function public.staff_get_document_stock_by_warehouse(text, text, text, text) to anon;

-- ============================================================================
-- 9. Order Serials FactBox / Show Serials / Print Serial Labels: the reserved units too, with a status
-- ============================================================================

drop function if exists public.staff_get_online_order_serial_labels(text, text, text);

create or replace function public.staff_get_online_order_serial_labels(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(serial_no text, item_code text, description text, status text)
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
    select s."SerialNo"::text, s."ItemCode"::text, coalesce(nullif(trim(s."ItemDescription"), ''), s."ItemCode")::text,
           s."Status"::text
    from public."ItemSerialTracking" s
    where (s."SoldOnlineOrderId" = p_order_id and coalesce(s."Status", '') not in ('REVERSED', 'RESERVED'))
       or (s."Status" = 'RESERVED' and s."ReservedForOrderId" = p_order_id)
    order by (s."Status" = 'RESERVED'), s."ItemCode", s."SerialNo";
end;
$$;

grant execute on function public.staff_get_online_order_serial_labels(text, text, text) to anon;

drop function if exists public.staff_get_advance_order_serial_labels(text, text, text);

create or replace function public.staff_get_advance_order_serial_labels(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(serial_no text, item_code text, description text, status text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._advance_order_can_view(p_admin_username, p_no) then
    raise exception 'Not authorized.';
  end if;

  return query
    select x.serial_no, x.item_code, x.description, x.status
    from (
      select s."SerialNo"::text as serial_no, s."ItemCode"::text as item_code,
             coalesce(nullif(trim(s."ItemDescription"), ''), s."ItemCode")::text as description, s."Status"::text as status
      from public._advance_order_serials(p_no) s
      where coalesce(s."Status", '') not in ('REVERSED', 'RESERVED')
      union
      select s."SerialNo"::text, s."ItemCode"::text,
             coalesce(nullif(trim(s."ItemDescription"), ''), s."ItemCode")::text, s."Status"::text
      from public."ItemSerialTracking" s
      where s."Status" = 'RESERVED' and s."ReservedForOrderId" = 'ADV-' || p_no
    ) x
    order by (x.status = 'RESERVED'), x.item_code, x.serial_no;
end;
$$;

grant execute on function public.staff_get_advance_order_serial_labels(text, text, text) to anon;

-- ============================================================================
-- 10. Serial Tracker search: who a serial is reserved for
-- ============================================================================

-- supabase_serial_tracker_sort_latest_update.sql's version plus reserved_for_order_id / reserved_at_utc /
-- reserved_by (filled only while RESERVED). A search also matches the reserved order no.
drop function if exists public.staff_search_item_serial_tracking(text, text, text, text, text, text, int, text, text);

create or replace function public.staff_search_item_serial_tracking(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_location_restrict text default null,
  p_location_filter text default null,
  p_limit int default 500,
  p_category_code text default null,
  p_variant_filter text default null
)
returns table(
  serial_no text,
  item_code text,
  item_description text,
  variant_code text,
  location text,
  status text,
  source_document_no text,
  sold_receipt_no text,
  sold_online_order_id text,
  created_at_utc timestamptz,
  updated_at_utc timestamptz,
  updated_by text,
  variant_sku text,
  colour text,
  reserved_for_order_id text,
  reserved_at_utc timestamptz,
  reserved_by text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 2000);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      s."SerialNo"::text, s."ItemCode"::text, s."ItemDescription"::text, s."VariantCode"::text, s."Location"::text, s."Status"::text,
      s."SourceDocumentNo"::text, s."SoldReceiptNo"::text, s."SoldOnlineOrderId"::text,
      s."CreatedAtUtc", s."UpdatedAtUtc", s."UpdatedBy"::text,
      nullif(trim(v."SKU"), '')::text,
      public._production_colour(v."VariantName", v."SKU", vi."Name", s."ItemDescription"),
      case when s."Status" = 'RESERVED' then s."ReservedForOrderId"::text end,
      case when s."Status" = 'RESERVED' then s."ReservedAtUtc" end,
      case when s."Status" = 'RESERVED' then s."ReservedBy"::text end
    from public."ItemSerialTracking" s
    left join public."Variants" v on v."VariationId" = nullif(trim(s."VariantCode"), '')
    left join public."Items" vi on vi."Code" = v."ItemCode"
    where (p_search is null or trim(p_search) = '' or
           s."SerialNo" ilike '%' || p_search || '%' or
           s."ItemCode" ilike '%' || p_search || '%' or
           s."ItemDescription" ilike '%' || p_search || '%' or
           v."SKU" ilike '%' || p_search || '%' or
           (s."Status" = 'RESERVED' and s."ReservedForOrderId" ilike '%' || p_search || '%'))
      and (p_status is null or trim(p_status) = '' or s."Status" = p_status)
      and (p_location_restrict is null or trim(p_location_restrict) = '' or lower(trim(s."Location")) = lower(trim(p_location_restrict)))
      and (p_location_filter is null or trim(p_location_filter) = '' or lower(trim(s."Location")) = lower(trim(p_location_filter)))
      and (p_category_code is null or trim(p_category_code) = '' or exists (
        select 1 from public."Items" i
        where i."Code" = s."ItemCode"
          and trim(coalesce(i."CategoryCode", '')) = trim(p_category_code)
      ))
      and (p_variant_filter is null or trim(p_variant_filter) = '' or coalesce(trim(s."VariantCode"), '') = trim(p_variant_filter))
    -- Latest change first (supabase_serial_tracker_sort_latest_update.sql).
    order by coalesce(s."UpdatedAtUtc", s."CreatedAtUtc") desc nulls last, s."SerialNo" desc
    limit v_limit;
end;
$$;

grant execute on function public.staff_search_item_serial_tracking(text, text, text, text, text, text, int, text, text) to anon;

-- ============================================================================
-- 11. Mark Floating skips reserved serials
-- ============================================================================

-- supabase_serial_bulk_floating.sql's version plus RESERVED in the skip list: Float + Release would
-- otherwise put a reserved unit back IN_STOCK and silently drop its order's reservation.
create or replace function public.admin_bulk_set_serial_status(
  p_admin_username text,
  p_admin_password text,
  p_serial_nos text[],
  p_status text
)
returns table(serial_no text, changed boolean, reason text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text := upper(trim(coalesce(p_status, '')));
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User can change serials in bulk.';
  end if;
  if v_status not in ('FLOATING', 'IN_STOCK') then
    raise exception 'Bulk status can only be FLOATING or IN_STOCK.';
  end if;
  if coalesce(array_length(p_serial_nos, 1), 0) = 0 then
    raise exception 'No serials selected.';
  end if;
  if array_length(p_serial_nos, 1) > 2000 then
    raise exception 'Change at most 2000 serials at a time.';
  end if;

  return query
  with wanted as (
    select distinct trim(x) as sn from unnest(p_serial_nos) as x where nullif(trim(x), '') is not null
  ),
  current_rows as (
    select w.sn, s."RunningSerialNo", upper(coalesce(s."Status", '')) as status
    from wanted w
    left join public."ItemSerialTracking" s on s."SerialNo" = w.sn
  ),
  done as (
    update public."ItemSerialTracking" s
      set "Status" = v_status, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
      from current_rows c
      where s."RunningSerialNo" = c."RunningSerialNo"
        and case when v_status = 'FLOATING'
                 then c.status not in ('SOLD', 'IN_TRANSIT', 'FLOATING', 'RESERVED')
                 else c.status = 'FLOATING' end
      returning s."SerialNo"
  )
  select c.sn,
         (d."SerialNo" is not null),
         case
           when d."SerialNo" is not null then null
           when c."RunningSerialNo" is null then 'Not found'
           when v_status = 'IN_STOCK' then 'Not floating (' || lower(c.status) || ')'
           when c.status = 'SOLD' then 'Sold - tied to a sale'
           when c.status = 'IN_TRANSIT' then 'In transit on a Transfer Order'
           when c.status = 'RESERVED' then 'Reserved for an order - Release Reservation first'
           when c.status = 'FLOATING' then 'Already floating'
           else 'Not changed'
         end
  from current_rows c
  left join done d on d."SerialNo" = c.sn
  order by c.sn;
end;
$$;

grant execute on function public.admin_bulk_set_serial_status(text, text, text[], text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('_serial_order_link', '_serial_order_is_open', '_serial_can_manage_reservations',
                    '_serial_release_order_reservations', '_serial_reserve_on_output',
                    'staff_reserve_serials_for_order', 'staff_release_serial_reservations',
                    'admin_update_online_order_status', 'staff_advance_order_to_ship_with_serials',
                    'staff_get_online_order_stock_status', 'staff_get_lines_stock_by_warehouse',
                    'staff_get_document_stock_by_warehouse', 'staff_get_online_order_serial_labels',
                    'staff_get_advance_order_serial_labels', 'staff_search_item_serial_tracking',
                    'admin_bulk_set_serial_status')
union all
select 'trigger', t.tgname::text, c.relname::text
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
where t.tgname in ('TR_ProductionOrderOutputSerials_Reserve', 'TR_OnlineOrders_SerialReservation',
                   'TR_AdvanceOrders_SerialReservation')
union all
select 'column', a.attname::text, 'ItemSerialTracking'
from pg_attribute a
where a.attrelid = 'public."ItemSerialTracking"'::regclass
  and a.attname in ('ReservedForOrderId', 'ReservedAtUtc', 'ReservedBy') and not a.attisdropped
order by 1, 2;
