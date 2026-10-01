-- Walk-in orders: portal-only production status - per "for walkin orders we can maintain portal only
-- status.. no need to change status to pancake".
--
-- Why: the POS creates every walk-in in Pancake as Shipped (status 2, OnlinefunctionsEvents.cs
-- CreateInstoreOnlineOrder), and the maker flow only ever moved Confirmed / Printed orders - so
-- assigning a maker on a walk-in saved the name and nothing else happened (never Assigned, never on
-- the maker's My Assignments, Production Done refused "already Shipped").
--
-- Now a walk-in that needs a maker (custom line, or 10mm / 12mm glass - _online_order_production_roles)
-- gets a portal-only stage. Status / Pancake are NOT touched - the sale stays Shipped for Pancake, the
-- dashboard and the sales reports:
--   To Assign       - not every needed maker is set yet
--   Assigned        - every needed maker set, not all parts marked done
--   Production Done - every part marked done by its maker
--   Completed       - handed to the customer (Mark Picked Up -> OnlineOrders."PickedUpAtUtc")
-- Worked out live from the makers + their Production Done marks (_walkin_order_stage), so it can't
-- drift: unassigning or undoing Production Done moves it back on its own. Only one new fact is stored:
-- when it was picked up.
--
-- Go-live: only walk-ins dated on/after _walkin_flow_start() (2026-10-01) enter the flow on their own;
-- an older one only if a maker was assigned to it (e.g. 100768). The 2,500+ older custom walk-ins stay
-- under Shipped.
--
-- Also:
--   - Walk-in customer name / contact no. (portal only) - POS walk-ins all come in as
--     "POS WALKIN ORDERS" / 11111. Shown as the order's customer everywhere once filled in.
--   - Walk-in due date (portal only, "WalkinDueDate") - set the moment every needed maker is assigned,
--     from the glass turnaround days (GlassPricingSetup, same rule as online orders). Separate from
--     EstimatedDeliveryDate because the Pancake sync overwrites that one.
--   - Production Done / Send Back now work for walk-ins in the flow (they refused anything Shipped).
--   - Walk-in tab counts: To Assign / Assigned / Production Done / Completed / Shipped / Cancelled.
--   - Online AND walk-in: once an order needs a Tank Maker, any stand / top cover line on it (custom
--     or not) also needs a Stand Maker (_online_order_production_roles, below). The list's
--     has_aquarium_line / has_stand_line and the Assigned counts now all use that one rule.
--
-- Run AFTER supabase_online_order_thick_glass_tank_maker.sql (re-creates admin_list_online_orders /
-- admin_get_online_order_status_summary from it). Adds nullable columns to OnlineOrders (a brief lock -
-- if it times out waiting for the sync, just run it again). Safe to re-run.

set lock_timeout = '10s';

alter table public."OnlineOrders" add column if not exists "WalkinCustomerName" varchar(200);
alter table public."OnlineOrders" add column if not exists "WalkinCustomerPhone" varchar(50);
alter table public."OnlineOrders" add column if not exists "WalkinDueDate" date;
alter table public."OnlineOrders" add column if not exists "PickedUpAtUtc" timestamptz;
alter table public."OnlineOrders" add column if not exists "PickedUpBy" varchar(100);

reset lock_timeout;

-- ---------------------------------------------------------------------------
-- Stand Maker for any stand on a maker order - per "can you check the stand maker too i notice the
-- order has stand needed a stand maker". Before, only a CUSTOM stand / top cover needed a Stand Maker,
-- so a 10mm / 12mm order (Tank Maker because of the glass) with a regular stand line had nobody on the
-- stand - and maker orders skip the stock check, so it was never picked from stock either. Now: once an
-- order needs a Tank Maker (custom tank line or 10mm / 12mm glass), ANY stand / top cover line on it
-- also needs a Stand Maker. Orders with no maker work are unchanged (stock flow / POS).
-- Same stand rule as _online_order_line_part ("standard" isn't a stand).
create or replace function public._online_order_is_stand_line(p_description text, p_item_code text)
returns boolean
language sql
immutable
as $$
  select (coalesce(p_description, '') || ' ' || coalesce(p_item_code, '')) ~* '(stand(?!ard)|top[[:space:]_-]*cover)';
$$;

revoke execute on function public._online_order_is_stand_line(text, text) from public, anon, authenticated;

-- Replaces supabase_online_order_thick_glass_tank_maker.sql's version (adds the any-stand rule). Drives
-- Production Done, My Assignments, assignment complete (-> Assigned), walk-in stages, and (below) the
-- list's has_aquarium_line / has_stand_line and the status counts.
create or replace function public._online_order_production_roles(p_order_id text)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  with f as (
    select
      exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'tank'
      ) or exists (
        -- 10mm / 12mm orders always need a Tank Maker.
        select 1 from public."OnlineOrders" o
        where o."OrderID" = p_order_id and public._online_order_thick_glass(o."GlassThickness")
      ) as tank,
      exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'stand'
      ) as custom_stand,
      exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id and public._online_order_is_stand_line(ol."Description", ol."ItemCode")
      ) as any_stand
  )
  select (case when f.tank then array['tank'] else array[]::text[] end)
      || (case when f.custom_stand or (f.tank and f.any_stand) then array['stand'] else array[]::text[] end)
  from f;
$$;

revoke execute on function public._online_order_production_roles(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Go-live date: walk-ins before this only enter the flow when a maker was assigned.
create or replace function public._walkin_flow_start()
returns date
language sql
immutable
as $$
  select date '2026-10-01';
$$;

-- The walk-in's portal stage, or null when it isn't in the flow (online order, cancelled, nothing to
-- make, or an old walk-in nobody assigned). Cheap tests first so old walk-ins never compute roles.
create or replace function public._walkin_order_stage(p_order_id text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when o."ReceivedAtShop" is not true then null
    when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then null
    when (o."Date" is null or o."Date" < public._walkin_flow_start())
         and nullif(trim(coalesce(o."AssignedTankMaker", '')), '') is null
         and nullif(trim(coalesce(o."AssignedStandMaker", '')), '') is null then null
    else case
      when cardinality(public._online_order_production_roles(o."OrderID")) = 0 then null
      when o."PickedUpAtUtc" is not null then 'Completed'
      when public._online_order_production_all_done(o."OrderID") then 'Production Done'
      when public._online_order_assignment_complete(o."OrderID") then 'Assigned'
      else 'To Assign'
    end
  end
  from public."OnlineOrders" o
  where o."OrderID" = p_order_id;
$$;

revoke execute on function public._walkin_order_stage(text) from public, anon, authenticated;

-- Production can still be marked / undone / sent back: an open walk-in stage, or (online orders) the
-- usual Confirmed / Printed / Assigned.
create or replace function public._online_order_production_open(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public._walkin_order_stage(p_order_id) in ('To Assign', 'Assigned', 'Production Done'), false)
      or exists (
        select 1 from public."OnlineOrders" o
        where o."OrderID" = p_order_id
          and lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned')
      );
$$;

revoke execute on function public._online_order_production_open(text) from public, anon, authenticated;

-- Glass turnaround days of the order's thickest glass (12mm > 10mm > 6mm > 3mm in its lines, else the
-- order's 10mm/12mm flag) - same lookup as admin_sync_online_order_assigned_status. Null = none.
create or replace function public._online_order_glass_lead_days(p_order_id text)
returns int
language sql
stable
security definer
set search_path = public
as $$
  with thickness as (
    select coalesce(
      (select t.thickness
         from (values ('12mm', 1), ('10mm', 2), ('6mm', 3), ('3mm', 4)) as t(thickness, priority)
        where exists (
          select 1 from public."OnlineOrderLines" ol
          where ol."OrderID" = p_order_id
            and regexp_replace(coalesce(ol."Description", '') || coalesce(ol."Note", '') || coalesce(ol."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%' || t.thickness || '%'
        )
        order by t.priority
        limit 1),
      (select lower(regexp_replace(o."GlassThickness", '\s+', '', 'g')) from public."OnlineOrders" o where o."OrderID" = p_order_id)
    ) as v
  )
  select max(m[1]::int)
  from thickness th, public."GlassPricingSetup" g,
       regexp_matches(coalesce(g."TurnAroundDays", ''), '([0-9]+)', 'g') as m
  where th.v is not null
    and regexp_replace(upper(coalesce(g."Thickness", '')), '[[:space:]]+', '', 'g')
        in (upper(th.v), regexp_replace(th.v, '[^0-9]', '', 'g'));
$$;

revoke execute on function public._online_order_glass_lead_days(text) from public, anon, authenticated;

-- Walk-in due date: set once, the moment every needed maker is assigned (portal only).
create or replace function public._walkin_order_due_date_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_roles text[];
  v_days int;
begin
  if new."ReceivedAtShop" is not true or new."WalkinDueDate" is not null then
    return new;
  end if;
  v_roles := public._online_order_production_roles(new."OrderID");
  if cardinality(v_roles) > 0
     and (not 'tank' = any(v_roles) or nullif(trim(coalesce(new."AssignedTankMaker", '')), '') is not null)
     and (not 'stand' = any(v_roles) or nullif(trim(coalesce(new."AssignedStandMaker", '')), '') is not null) then
    v_days := public._online_order_glass_lead_days(new."OrderID");
    if coalesce(v_days, 0) > 0 then
      new."WalkinDueDate" := (now() at time zone 'Asia/Manila')::date + v_days;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_walkin_order_due_date on public."OnlineOrders";
create trigger trg_walkin_order_due_date
before update of "AssignedTankMaker", "AssignedStandMaker" on public."OnlineOrders"
for each row execute function public._walkin_order_due_date_trigger();

-- ---------------------------------------------------------------------------
-- Production Done - same as supabase_online_order_production_done.sql, except the status gate is
-- _online_order_production_open (walk-ins in the flow are Shipped in Pancake).
create or replace function public.staff_set_online_order_production_done(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_done boolean default true
)
returns table(success boolean, message text, all_done boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public."OnlineOrders"%rowtype;
  v_needed text[];
  v_mine text[] := array[]::text[];
  v_all_done boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text, false;
    return;
  end if;

  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    return query select false, 'Order not found.'::text, false;
    return;
  end if;

  -- WALK-IN: open walk-in stages count too.
  if not public._online_order_production_open(p_order_id) then
    return query select false, format('This order is already %s - production can''t be changed.',
      coalesce(public._walkin_order_stage(p_order_id), v_order."Status"))::text, false;
    return;
  end if;

  v_needed := public._online_order_production_roles(p_order_id);
  if 'tank' = any(v_needed) and v_order."AssignedTankMaker" = p_admin_username then v_mine := array_append(v_mine, 'tank'); end if;
  if 'stand' = any(v_needed) and v_order."AssignedStandMaker" = p_admin_username then v_mine := array_append(v_mine, 'stand'); end if;
  if 'dispatcher' = any(v_needed) and v_order."AssignedDispatcher" = p_admin_username then v_mine := array_append(v_mine, 'dispatcher'); end if;

  if cardinality(v_mine) = 0 then
    return query select false, 'You are not assigned to a production part of this order.'::text, false;
    return;
  end if;

  if p_done then
    insert into public."OnlineOrderProductionDone" ("OrderID", "Role", "DoneBy", "DoneAtUtc")
    select p_order_id, r, p_admin_username, now() from unnest(v_mine) as r
    on conflict ("OrderID", "Role") do update set "DoneBy" = excluded."DoneBy", "DoneAtUtc" = excluded."DoneAtUtc";
  else
    delete from public."OnlineOrderProductionDone" where "OrderID" = p_order_id and "Role" = any(v_mine);
  end if;

  select bool_and(exists (
    select 1 from public."OnlineOrderProductionDone" d
    where d."OrderID" = p_order_id and d."Role" = r
      and d."DoneBy" = case r when 'tank' then v_order."AssignedTankMaker" when 'stand' then v_order."AssignedStandMaker" else v_order."AssignedDispatcher" end
  )) into v_all_done
  from unnest(v_needed) as r;

  return query select true, (case when p_done then 'Marked as done.' else 'Production done undone.' end)::text, coalesce(v_all_done, false);
end;
$$;

grant execute on function public.staff_set_online_order_production_done(text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Send Back - same as supabase_online_order_production_rework.sql, except the status gate.
create or replace function public.admin_send_back_online_order_production(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_roles text[],
  p_reason text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_count int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if not exists (
    select 1 from public."StaffUsers"
    where "Username" = p_admin_username and "IsActive"
      and ("SuperUser" or 'ProductionManager' = any("StaffRoles"))
  ) then
    return query select false, 'Only a Production Manager can send work back.'::text;
    return;
  end if;

  if v_reason is null then
    return query select false, 'Please give a reason so the maker knows what to fix.'::text;
    return;
  end if;

  if p_roles is null or cardinality(p_roles) = 0 then
    return query select false, 'Pick at least one part to send back.'::text;
    return;
  end if;

  select "Status" into v_status from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    return query select false, 'Order not found.'::text;
    return;
  end if;

  -- WALK-IN: open walk-in stages count too.
  if not public._online_order_production_open(p_order_id) then
    return query select false, format('This order is already %s - it can''t be sent back from here.',
      coalesce(public._walkin_order_stage(p_order_id), v_status))::text;
    return;
  end if;

  with removed as (
    delete from public."OnlineOrderProductionDone"
    where "OrderID" = p_order_id and "Role" = any(p_roles)
    returning "Role", "DoneBy", "DoneAtUtc"
  ), logged as (
    insert into public."OnlineOrderProductionRework" ("OrderID", "Role", "Reason", "SentBackBy", "PrevDoneBy", "PrevDoneAtUtc")
    select p_order_id, r."Role", v_reason, p_admin_username, r."DoneBy", r."DoneAtUtc" from removed r
    returning 1
  )
  select count(*) into v_count from logged;

  if v_count = 0 then
    return query select false, 'None of those parts were marked done.'::text;
    return;
  end if;

  return query select true, format('Sent back %s part(s) for rework.', v_count)::text;
end;
$$;

grant execute on function public.admin_send_back_online_order_production(text, text, text, text[], text) to anon;

-- ---------------------------------------------------------------------------
-- Walk-in customer name / contact no. (portal only). Any staff except maker-only accounts.
create or replace function public.admin_set_walkin_order_customer(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_name text,
  p_phone text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or public._is_order_maker_only(p_admin_username) then
    raise exception 'Not authorized.';
  end if;

  update public."OnlineOrders"
     set "WalkinCustomerName" = nullif(trim(coalesce(p_name, '')), ''),
         "WalkinCustomerPhone" = nullif(trim(coalesce(p_phone, '')), '')
   where "OrderID" = p_order_id and "ReceivedAtShop" is true;

  if not found then
    raise exception 'Walk-in order % not found.', p_order_id;
  end if;
end;
$$;

grant execute on function public.admin_set_walkin_order_customer(text, text, text, text, text) to anon;

-- Mark Picked Up (p_picked_up = true, only from Production Done) or undo it (false). Any staff except
-- maker-only accounts - whoever hands the tank over at the counter.
create or replace function public.admin_mark_walkin_order_picked_up(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_picked_up boolean default true
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stage text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or public._is_order_maker_only(p_admin_username) then
    raise exception 'Not authorized.';
  end if;

  v_stage := public._walkin_order_stage(p_order_id);
  if coalesce(p_picked_up, true) then
    if v_stage is distinct from 'Production Done' then
      raise exception 'Order % is %, not Production Done - every maker has to mark their part done first.',
        p_order_id, coalesce(v_stage, 'not a walk-in in production');
    end if;
    update public."OnlineOrders" set "PickedUpAtUtc" = now(), "PickedUpBy" = p_admin_username where "OrderID" = p_order_id;
  else
    if v_stage is distinct from 'Completed' then
      raise exception 'Order % is not marked picked up.', p_order_id;
    end if;
    update public."OnlineOrders" set "PickedUpAtUtc" = null, "PickedUpBy" = null where "OrderID" = p_order_id;
  end if;
end;
$$;

grant execute on function public.admin_mark_walkin_order_picked_up(text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text, text[], boolean);

create or replace function public.admin_list_online_orders(
  p_admin_username text, p_admin_password text,
  p_search text default null, p_status text default null, p_order_id text default null,
  p_period text default null, p_walkin_only boolean default false,
  p_page int default 1, p_page_size int default 50,
  p_confirmed_by text default null,
  -- p_status_in (folded back in from supabase_online_order_staff_status_scope.sql, see the drop
  -- comment above): Online Order Staff's exact-match Confirmed/Printed/To Ship lock. Takes over
  -- filtering entirely when provided; p_status is ignored (same contract as that file described).
  p_status_in text[] default null,
  -- p_assigned_to_me (supabase_online_order_my_assignments.sql): only orders where the caller is
  -- the Tank Maker, Stand Maker or Dispatcher, and not yet Shipped/Received/Cancelled.
  p_assigned_to_me boolean default false
)
returns table(
  order_id text,
  order_date date,
  order_time text,
  status text,
  customer_name text,
  location_id text,
  warehouse_name text,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
  balance numeric,
  for_delivery boolean,
  shipping_address text,
  estimated_delivery_date date,
  last_updated_at timestamptz,
  synced_at_utc timestamptz,
  glass_thickness text,
  created_by text,
  confirmed_by text,
  note_print text,
  delivery_fee numeric,
  has_custom_line boolean,
  assigned_production_member text,
  assigned_production_member_name text,
  -- has_aquarium_line / has_stand_line: per "maybe each order can be assign a tank maker and a
  -- stand maker. if an order has Aquarium order assign tank maker, if stand then we can assign
  -- stand maker" (supabase_online_order_production_assignment.sql's AssignedTankMaker/
  -- AssignedStandMaker) - same custom-line detection as has_custom_line above, narrowed to the
  -- 'aquarium'/'stand' keyword so the portal can gate each maker dropdown to only the orders that
  -- actually need that role, rather than always showing both.
  has_aquarium_line boolean,
  has_stand_line boolean,
  assigned_tank_maker text,
  assigned_tank_maker_name text,
  assigned_stand_maker text,
  assigned_stand_maker_name text,
  is_gma_order boolean,
  gma_order_no text,
  -- WALK-IN portal status (this file): stage (null = not in the flow), raw portal customer fields
  -- (customer_name above already shows the portal name once filled in), pick-up stamp.
  received_at_shop boolean,
  walkin_stage text,
  walkin_customer_name text,
  walkin_customer_phone text,
  picked_up_at timestamptz,
  picked_up_by_name text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
  v_today date;
  v_prev_month_start date;
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_mine boolean := coalesce(p_assigned_to_me, false);
  v_is_dispatcher boolean := false;
  v_my_warehouse text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Staff whose only access is a maker role can only ever list their own assignments.
  if public._is_order_maker_only(p_admin_username) then
    v_mine := true;
  end if;

  select coalesce('Dispatcher' = any(s."StaffRoles"), false), nullif(trim(coalesce(s."WarehouseName", '')), '')
    into v_is_dispatcher, v_my_warehouse
  from public."StaffUsers" s where s."Username" = p_admin_username;

  if p_period in ('month', 'today', 'prevmonth') then
    v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
    v_month_end := (v_month_start + interval '1 month')::date;
    v_today := (now() at time zone 'Asia/Manila')::date;
    v_prev_month_start := (v_month_start - interval '1 month')::date;
  end if;

  return query
    select o."OrderID"::text, o."Date", o."Time"::text, o."Status"::text,
           -- WALK-IN: the portal customer name once filled in (POS walk-ins are all "POS WALKIN ORDERS").
           coalesce(nullif(trim(o."WalkinCustomerName"), ''), o."CustomerName")::text,
           o."LocationID"::text, w."Name"::text,
           o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance", o."ForDelivery", o."ShippingAddress"::text,
           -- WALK-IN: portal-only due date (the Pancake sync overwrites EstimatedDeliveryDate).
           case when o."ReceivedAtShop" is true then coalesce(o."WalkinDueDate", o."EstimatedDeliveryDate") else o."EstimatedDeliveryDate" end,
           o."Last_Updated_At", o."SyncedAtUtc", o."GlassThickness"::text,
           o."CreatedBy"::text, o."ConfirmedBy"::text, o."NotePrint"::text, o."DeliveryFee",
           exists (
             select 1 from public."OnlineOrderLines" ol
             where ol."OrderID" = o."OrderID"
               and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
           ),
           o."AssignedProductionMember"::text, spm."DisplayName"::text,
           -- has_aquarium_line / has_stand_line = needs a Tank / Stand Maker - the one shared rule
           -- (custom lines, 10mm / 12mm glass, any stand on a maker order).
           'tank' = any(public._online_order_production_roles(o."OrderID")),
           'stand' = any(public._online_order_production_roles(o."OrderID")),
           o."AssignedTankMaker"::text, tank."DisplayName"::text,
           o."AssignedStandMaker"::text, stand."DisplayName"::text,
           -- GMA-conversation-originated flag: joined by matching this AutomatedOrders row's own
           -- captured receipt_no (supabase_gma_conversation_orders.sql - same field Pancake gives
           -- back on order creation, no live Pancake call needed here) against this synced order's
           -- OrderID, rather than anything derived from OnlineOrders.Page_ID/Conversation_ID -
           -- those are always the Pancake-connected page's own ids regardless of an order's real
           -- origin, since GMA runs on a separate, unconnected Facebook Page.
           (select ao."GmaPsid" is not null from public."AutomatedOrders" ao where ao."PancakeReceiptNo" = o."OrderID" limit 1),
           (select ao."OrderNo"::text from public."AutomatedOrders" ao where ao."PancakeReceiptNo" = o."OrderID" and ao."GmaPsid" is not null limit 1),
           coalesce(o."ReceivedAtShop", false),
           case when o."ReceivedAtShop" is true then public._walkin_order_stage(o."OrderID") end,
           o."WalkinCustomerName"::text, o."WalkinCustomerPhone"::text,
           o."PickedUpAtUtc", coalesce(pu."DisplayName", o."PickedUpBy")::text,
           count(*) over()
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    left join public."StaffUsers" pu on pu."Username" = o."PickedUpBy"
    left join public."StaffUsers" spm on spm."Username" = o."AssignedProductionMember"
    left join public."StaffUsers" tank on tank."Username" = o."AssignedTankMaker"
    left join public."StaffUsers" stand on stand."Username" = o."AssignedStandMaker"
    where (
        not v_mine
        or (
          -- CASE so the done check only runs for the caller's own open assignments. Orders where every
          -- part of theirs is already marked done drop out of their list
          -- (supabase_online_order_my_assignments_hide_done.sql).
          case
            -- Dispatchers see every To Ship order (their own branch's, if their account has one) so they
            -- can Mark Shipped what they deliver - they're recorded as its Dispatcher then
            -- (supabase_online_order_dispatcher_on_ship.sql).
            when coalesce(v_is_dispatcher, false)
              and lower(trim(coalesce(o."Status", ''))) in ('to ship', 'packing', 'packed')
              and (v_my_warehouse is null or w."Name" = v_my_warehouse)
              then true
            when p_admin_username in (o."AssignedTankMaker", o."AssignedStandMaker")
              -- WALK-IN: Shipped in Pancake from the start - open while its portal stage is.
              and (case when o."ReceivedAtShop" is true
                     then public._walkin_order_stage(o."OrderID") in ('To Assign', 'Assigned', 'Production Done')
                     else lower(trim(coalesce(o."Status", ''))) not in ('shipped', 'delivered', '2', 'received', '3', 'canceled', 'cancelled') end)
              then (
                not public._online_order_my_parts_done(o."OrderID", p_admin_username)
                -- The order's Dispatcher keeps its To Ship orders so they can Mark Shipped once delivered
                -- (supabase_online_order_mark_shipped.sql), even after their own part is done.
                or (o."AssignedDispatcher" = p_admin_username
                    and lower(trim(coalesce(o."Status", ''))) in ('to ship', 'packing', 'packed'))
              )
            else false
          end
        )
      )
      -- WALK-IN: My Assignments shows every order assigned to the caller, walk-in or online.
      and (v_mine or (case when p_walkin_only then o."ReceivedAtShop" is true else o."ReceivedAtShop" is not true end))
      and (p_period is distinct from 'month' or (o."Date" >= v_month_start and o."Date" < v_month_end))
      and (
        p_period is distinct from 'today'
        or (
          -- Widens "today" to the same ConfirmedAtUtc-based rule used by
          -- admin_get_sales_by_confirmed_by's daily_sales AND admin_get_online_order_financial_
          -- summary's today_online_sales - i.e. whenever this list is scoped to online orders
          -- (p_walkin_only false, the default) or to a specific staff member's Daily drill-down
          -- (p_confirmed_by set - always online-only anyway, per that function's own join). The
          -- Today's Walk-In Sales card (p_walkin_only true, no p_confirmed_by) keeps the plain
          -- Date = today behavior its own total is still computed with, so that figure and its
          -- drill-down list still always match.
          case
            when (p_confirmed_by is not null and trim(p_confirmed_by) <> '') or not p_walkin_only
              then coalesce((o."ConfirmedAtUtc" at time zone 'Asia/Manila')::date, o."Date") = v_today
            else o."Date" = v_today
          end
        )
      )
      and (p_period is distinct from 'prevmonth' or (o."Date" >= v_prev_month_start and o."Date" < v_month_start))
      and (p_confirmed_by is null or trim(p_confirmed_by) = '' or lower(trim(o."ConfirmedBy")) = lower(trim(p_confirmed_by)))
      and (
        (p_order_id is not null and trim(p_order_id) <> '' and o."OrderID" = p_order_id)
        or (
          (p_order_id is null or trim(p_order_id) = '')
          and (p_search is null or trim(p_search) = '' or o."OrderID" ilike '%' || p_search || '%' or o."CustomerName" ilike '%' || p_search || '%'
               or o."WalkinCustomerName" ilike '%' || p_search || '%' or o."WalkinCustomerPhone" ilike '%' || p_search || '%')
          and (
            case
              when p_status_in is not null and array_length(p_status_in, 1) > 0 then o."Status" = any(p_status_in)
              -- WALK-IN tab: its tabs are portal stages; Shipped = walk-ins not in the flow.
              when p_walkin_only and p_status is not null
                   and lower(trim(p_status)) in ('to assign', 'assigned', 'production done', 'completed') then
                lower(coalesce(public._walkin_order_stage(o."OrderID"), '')) = lower(trim(p_status))
              when p_walkin_only and p_status is not null and lower(trim(p_status)) = 'shipped' then
                case when lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2')
                  then public._walkin_order_stage(o."OrderID") is null else false end
              -- 'Assigned' isn't a real Status value (Status must keep mirroring Pancake - see
              -- supabase_online_order_production_assignment.sql's header comment) - it's the
              -- status-summary pill/grouped-tab's derived label for a Printed order whose every
              -- needed maker (Tank for an aquarium line, Stand for a stand line - an order can
              -- need one, the other, or both) is now assigned, so the filter is expressed in terms
              -- of the real columns instead. Same split admin_get_online_order_status_summary
              -- below now makes; an order with neither line type never has anything to assign, so
              -- it can never land in 'Assigned' - it just stays 'Printed'.
              -- 'Production Done' (supabase_online_order_production_done_tab.sql): every needed part
              -- marked done by its current assignee, order not moved on yet. Such orders leave the
              -- Assigned / other status filters so each order sits under exactly one tab.
              -- CASE (not AND/OR) so _online_order_production_all_done only runs for rows that already
              -- passed the cheap status test - Postgres doesn't guarantee AND/OR evaluation order, and
              -- running it for every order in the table hit "canceling statement due to statement timeout".
              when p_status is not null and lower(trim(p_status)) = 'production done' then
                case when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned')
                  then public._online_order_production_all_done(o."OrderID")
                  else false end
              when p_status is not null and lower(trim(p_status)) = 'assigned' then
                case when (
                  lower(trim(coalesce(o."Status", ''))) = 'assigned'
                  -- Printed + every needed maker set (same roles rule as everywhere else).
                  -- CASE so the roles check only runs for Printed orders (see the timeout note above).
                  or (case when o."Status" ilike '%printed%' then public._online_order_assignment_complete(o."OrderID") else false end))
                  then not public._online_order_production_all_done(o."OrderID")
                  else false end
              else
                case
                  when p_status is null or trim(p_status) = '' then true
                  when o."Status" not ilike '%' || p_status || '%' then false
                  when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned') then not public._online_order_production_all_done(o."OrderID")
                  else true
                end
            end
          )
        )
      )
    order by o."Last_Updated_At" desc nulls last, o."Date" desc nulls last
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text, text[], boolean) to anon;

-- ---------------------------------------------------------------------------
-- Status counts. Online tab: same as supabase_online_order_thick_glass_tank_maker.sql. Walk-in tab
-- (p_walkin_only): To Assign / Assigned / Production Done / Completed from the portal stage, the rest
-- Shipped / Cancelled from Pancake's status.
create or replace function public.admin_get_online_order_status_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null, p_walkin_only boolean default false)
returns table(status_label text, order_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if coalesce(p_walkin_only, false) then
    return query
      with buckets(status_label, sort_order) as (
        values ('To Assign', 1), ('Assigned', 2), ('Production Done', 3), ('Completed', 4), ('Shipped', 5), ('Cancelled', 6)
      ),
      order_buckets as (
        select
          case
            when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
            else coalesce(public._walkin_order_stage(o."OrderID"),
                   case when lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2') then 'Shipped' end)
          end as status_label
        from public."OnlineOrders" o
        left join public."Warehouses" w on w."ID" = o."LocationID"
        where o."ReceivedAtShop" is true
          and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name)
      )
      select b.status_label, count(ob.status_label)::int as order_count
      from buckets b
      left join order_buckets ob on ob.status_label = b.status_label
      group by b.status_label, b.sort_order
      order by b.sort_order;
    return;
  end if;

  return query
    with buckets(status_label, sort_order) as (
      values ('Confirmed', 1), ('Printed', 2), ('Assigned', 3), ('Production Done', 4), ('To Ship', 5), ('Shipped', 6), ('Cancelled', 7)
    ),
    order_flags as (
      select
        o.*,
        -- Needed makers - only worked out for Printed orders, the one bucket that uses them.
        case when lower(trim(coalesce(o."Status", ''))) = 'printed'
          then public._online_order_assignment_complete(o."OrderID") else false end as all_assigned
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where o."ReceivedAtShop" is not true
        and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name)
    ),
    order_buckets as (
      select
        case
          -- CASE-gated so the done check only runs for open orders (see the list function above).
          when case when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned')
                 then public._online_order_production_all_done(o."OrderID") else false end then 'Production Done'
          when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted') then 'Confirmed'
          when lower(trim(coalesce(o."Status", ''))) = 'assigned' then 'Assigned'
          when lower(trim(coalesce(o."Status", ''))) = 'printed' then
            case when o.all_assigned then 'Assigned' else 'Printed' end
          when lower(trim(coalesce(o."Status", ''))) in ('to ship', 'packing', 'packed') then 'To Ship'
          when lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2') then 'Shipped'
          when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
          else null
        end as status_label
      from order_flags o
    )
    select b.status_label, count(ob.status_label)::int as order_count
    from buckets b
    left join order_buckets ob on ob.status_label = b.status_label
    group by b.status_label, b.sort_order
    order by b.sort_order;
end;
$$;

grant execute on function public.admin_get_online_order_status_summary(text, text, text, boolean) to anon;

notify pgrst, 'reload schema';

-- Check after running (no changes):
-- select "OrderID", "Status", public._walkin_order_stage("OrderID") from public."OnlineOrders" where "OrderID" = '100768';
