-- "All-Branch Fabrication" Staff Role - per "my goal is to see the order from another branch if its
-- customize / 10mm or 12mm or needing fabrication ... just show it to the user that has the correct
-- permission".
--
-- Branch staff (StaffUsers.WarehouseName set) only see their own branch's orders on Online Orders.
-- Ticking this role (User Setup > Employee > Roles) also shows them OPEN fabrication orders from every
-- other branch - "fabrication" = needs a Tank / Stand Maker (_online_order_production_roles: custom
-- line, 10mm / 12mm glass, a stand on a maker order), the same rule the maker flow uses. Open =
-- Confirmed / Printed / Assigned / To Ship (online), or a To Assign / Assigned / Production Done
-- walk-in. They work those orders with their role's normal buttons.
--
-- Also moves the branch filter server-side (was done in the browser after paging, so a page of 50
-- could show 8): admin_list_online_orders and admin_get_online_order_status_summary gain an opt-in
-- p_branch_scoped flag - off by default, so other callers (GMA Conversations' customer order search,
-- the dashboard) keep their current all-branch results.
--
-- Run AFTER supabase_walkin_order_portal_status.sql. Re-running that file (or any older file that
-- re-creates these two functions) drops p_branch_scoped again - the page then falls back to its own
-- browser-side filter.

-- ---------------------------------------------------------------------------
-- Allowed roles

alter table public."StaffUsers" drop constraint if exists "CK_StaffUsers_StaffRoles";
alter table public."StaffUsers"
  add constraint "CK_StaffUsers_StaffRoles"
  check ("StaffRoles" <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier', 'ProductionManager', 'AllBranchFabrication']::text[]);

create or replace function public.admin_set_staff_user_roles(
  p_admin_username text,
  p_admin_password text,
  p_target_username text,
  p_roles text[]
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_roles text[] := coalesce(
    (select array_agg(distinct r order by r) from unnest(coalesce(p_roles, '{}')) r where nullif(trim(r), '') is not null),
    '{}'
  );
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if not (v_roles <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier', 'ProductionManager', 'AllBranchFabrication']::text[]) then
    return query select false, 'Roles must be Stand Maker, Tank Maker, Dispatcher, Cashier, Production Manager, or All-Branch Fabrication.'::text;
    return;
  end if;

  update public."StaffUsers" set "StaffRoles" = v_roles where "Username" = p_target_username;

  if not found then
    return query select false, 'That user no longer exists.'::text;
    return;
  end if;

  return query select true, 'Roles updated.'::text;
end;
$$;

grant execute on function public.admin_set_staff_user_roles(text, text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- An open order that needs fabrication - what an All-Branch Fabrication user sees from other branches.
-- Cheap status tests first so closed orders never compute roles.
create or replace function public._online_order_open_fabrication(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when o."ReceivedAtShop" is true
      then coalesce(public._walkin_order_stage(o."OrderID") in ('To Assign', 'Assigned', 'Production Done'), false)
    when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned', 'to ship', 'packing', 'packed')
      then cardinality(public._online_order_production_roles(o."OrderID")) > 0
    else false
  end
  from public."OnlineOrders" o
  where o."OrderID" = p_order_id;
$$;

revoke execute on function public._online_order_open_fabrication(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Same as supabase_walkin_order_portal_status.sql plus p_branch_scoped (see header).
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text, text[], boolean);
-- Stale older version (re-created if supabase_orders_sync_tables.sql was re-run) - would make named-arg
-- calls ambiguous. No-op if it isn't there.
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text, text[]);

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
  p_assigned_to_me boolean default false,
  -- p_branch_scoped (this file): only the caller's branch (StaffUsers.WarehouseName), plus other
  -- branches' open fabrication orders for an All-Branch Fabrication user. Off = every branch.
  p_branch_scoped boolean default false
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
  v_all_branch_fab boolean := false;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Staff whose only access is a maker role can only ever list their own assignments.
  if public._is_order_maker_only(p_admin_username) then
    v_mine := true;
  end if;

  select coalesce('Dispatcher' = any(s."StaffRoles"), false), nullif(trim(coalesce(s."WarehouseName", '')), ''),
         coalesce('AllBranchFabrication' = any(s."StaffRoles"), false)
    into v_is_dispatcher, v_my_warehouse, v_all_branch_fab
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
      -- Branch scope (this file). My Assignments keeps its own rules above. Orders with no resolved
      -- warehouse stay hidden while scoped (same as the page's old browser-side filter).
      and (
        not coalesce(p_branch_scoped, false) or v_mine or v_my_warehouse is null
        or w."Name" = v_my_warehouse
        -- CASE so the fabrication check only runs for open orders (see the timeout note below).
        -- Walk-ins: same cheap tests as _walkin_order_stage (not picked up; on/after go-live or a maker set)
        -- so the 2,500+ old walk-ins never reach the function.
        or (case when coalesce(v_all_branch_fab, false)
                   and ((o."ReceivedAtShop" is true and o."PickedUpAtUtc" is null
                         and (o."Date" >= public._walkin_flow_start()
                              or nullif(trim(coalesce(o."AssignedTankMaker", '')), '') is not null
                              or nullif(trim(coalesce(o."AssignedStandMaker", '')), '') is not null))
                        or (o."ReceivedAtShop" is not true
                            and lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned', 'to ship', 'packing', 'packed')))
              then public._online_order_open_fabrication(o."OrderID") else false end)
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

grant execute on function public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text, text[], boolean, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Status counts: same as supabase_walkin_order_portal_status.sql plus p_branch_scoped - the caller's
-- branch (p_warehouse_name) plus, for an All-Branch Fabrication user, other branches' open fabrication orders.
drop function if exists public.admin_get_online_order_status_summary(text, text, text, boolean);
-- Stale 3-arg version, same reason (the dashboard calls with 3 named args). No-op if it isn't there.
drop function if exists public.admin_get_online_order_status_summary(text, text, text);

create or replace function public.admin_get_online_order_status_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null, p_walkin_only boolean default false,
  p_branch_scoped boolean default false)
returns table(status_label text, order_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_all_branch_fab boolean := false;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if coalesce(p_branch_scoped, false) then
    select coalesce('AllBranchFabrication' = any(s."StaffRoles"), false) into v_all_branch_fab
    from public."StaffUsers" s where s."Username" = p_admin_username;
    v_all_branch_fab := coalesce(v_all_branch_fab, false);
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
          and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name
               or (case when v_all_branch_fab and o."PickedUpAtUtc" is null
                          and (o."Date" >= public._walkin_flow_start()
                               or nullif(trim(coalesce(o."AssignedTankMaker", '')), '') is not null
                               or nullif(trim(coalesce(o."AssignedStandMaker", '')), '') is not null)
                        then public._online_order_open_fabrication(o."OrderID") else false end))
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
        and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name
             or (case when v_all_branch_fab
                        and lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned', 'to ship', 'packing', 'packed')
                   then public._online_order_open_fabrication(o."OrderID") else false end))
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

grant execute on function public.admin_get_online_order_status_summary(text, text, text, boolean, boolean) to anon;
