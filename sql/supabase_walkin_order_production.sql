-- Walk-in orders through the maker flow - per "in the walk-in orders if i assign this order what will
-- happen? will this show on the assigned?" -> "yes" (make it work).
--
-- Before: assigning a Tank/Stand Maker on a walk-in (ReceivedAtShop) order saved, but the maker never
-- saw it - every list/count only ever looked at non-walk-in orders. Now:
--   1. admin_list_online_orders: My Assignments (p_assigned_to_me / maker-only accounts) ignores the
--      online/walk-in split, so a maker sees every order assigned to them, walk-in or not. Every other
--      list keeps the split (Online tab = online only, Walk-in tab = walk-ins only).
--   2. admin_get_online_order_status_summary: new p_walkin_only (default false = unchanged) so the
--      Walk-in tab gets its own Confirmed / Printed / Assigned / Production Done / ... counts.
--   3. admin_sync_online_order_assigned_status: no "your order is in production" Messenger message for
--      walk-ins (bought at the counter). The status move to Assigned (portal + Pancake) and the glass
--      turnaround ETA still happen, same as online orders.
-- Production Done (staff_set_online_order_production_done), Send Back and Mark Shipped never filtered
-- walk-ins out - nothing to change there.
--
-- Same bodies as supabase_online_order_maker_line_rules.sql / supabase_online_order_assigned_message_gma.sql
-- except for the lines marked "WALK-IN". Run AFTER both. Functions only - no table locks. Safe to re-run.

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
    select o."OrderID"::text, o."Date", o."Time"::text, o."Status"::text, o."CustomerName"::text, o."LocationID"::text, w."Name"::text,
           o."MoneyToCollect", o."AmountPaid", o."Discount", o."Balance", o."ForDelivery", o."ShippingAddress"::text,
           o."EstimatedDeliveryDate", o."Last_Updated_At", o."SyncedAtUtc", o."GlassThickness"::text,
           o."CreatedBy"::text, o."ConfirmedBy"::text, o."NotePrint"::text, o."DeliveryFee",
           exists (
             select 1 from public."OnlineOrderLines" ol
             where ol."OrderID" = o."OrderID"
               and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
           ),
           o."AssignedProductionMember"::text, spm."DisplayName"::text,
           exists (
             select 1 from public."OnlineOrderLines" ol
             where ol."OrderID" = o."OrderID"
               and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
               and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'tank'
           ),
           exists (
             select 1 from public."OnlineOrderLines" ol
             where ol."OrderID" = o."OrderID"
               and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
               and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'stand'
           ),
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
           count(*) over()
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
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
              and lower(trim(coalesce(o."Status", ''))) not in ('shipped', 'delivered', '2', 'received', '3', 'canceled', 'cancelled')
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
          and (p_search is null or trim(p_search) = '' or o."OrderID" ilike '%' || p_search || '%' or o."CustomerName" ilike '%' || p_search || '%')
          and (
            case
              when p_status_in is not null and array_length(p_status_in, 1) > 0 then o."Status" = any(p_status_in)
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
                  or (o."Status" ilike '%printed%'
                and exists (
                  select 1 from public."OnlineOrderLines" ol
                  where ol."OrderID" = o."OrderID"
                    and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
                    and (public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'tank'
                      or public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'stand')
                )
                and (
                  not exists (
                    select 1 from public."OnlineOrderLines" ol
                    where ol."OrderID" = o."OrderID"
                      and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
                      and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'tank'
                  )
                  or (o."AssignedTankMaker" is not null and trim(o."AssignedTankMaker") <> '')
                )
                and (
                  not exists (
                    select 1 from public."OnlineOrderLines" ol
                    where ol."OrderID" = o."OrderID"
                      and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
                      and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'stand'
                  )
                  or (o."AssignedStandMaker" is not null and trim(o."AssignedStandMaker") <> '')
                )))
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
drop function if exists public.admin_get_online_order_status_summary(text, text, text);

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

  return query
    with buckets(status_label, sort_order) as (
      -- 'Assigned' sits right after 'Printed' - it's not a real Status value (Status mirrors
      -- Pancake, see supabase_online_order_production_assignment.sql's header comment), just a
      -- derived split of Printed orders whose every needed maker (Tank/Stand - see needs_tank/
      -- needs_stand below) is now assigned (see order_buckets below and admin_list_online_orders'
      -- matching p_status = 'Assigned' case).
      values ('Confirmed', 1), ('Printed', 2), ('Assigned', 3), ('Production Done', 4), ('To Ship', 5), ('Shipped', 6), ('Cancelled', 7)
    ),
    order_flags as (
      select
        o.*,
        exists (
          select 1 from public."OnlineOrderLines" ol
          where ol."OrderID" = o."OrderID"
            and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
            and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'tank'
        ) as needs_tank,
        exists (
          select 1 from public."OnlineOrderLines" ol
          where ol."OrderID" = o."OrderID"
            and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
            and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'stand'
        ) as needs_stand
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      -- WALK-IN: the Walk-in tab counts walk-ins, every other caller online orders (unchanged).
      where (case when coalesce(p_walkin_only, false) then o."ReceivedAtShop" is true else o."ReceivedAtShop" is not true end)
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
            case
              when (o.needs_tank or o.needs_stand)
                and (not o.needs_tank or (o."AssignedTankMaker" is not null and trim(o."AssignedTankMaker") <> ''))
                and (not o.needs_stand or (o."AssignedStandMaker" is not null and trim(o."AssignedStandMaker") <> ''))
                then 'Assigned'
              else 'Printed'
            end
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

-- ---------------------------------------------------------------------------
create or replace function public.admin_sync_online_order_assigned_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(new_status text, changed boolean, estimated_delivery_date date, message_sent boolean, message_error text,
              gma_psid text, gma_message text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '60000'
as $$
declare
  v_status text;
  v_status_key text;
  v_pre_status text;
  v_eta date;
  v_new_eta date;
  v_complete boolean;
  v_target text;
  v_thickness text;
  v_lead_days int;
  v_payload jsonb;
  v_message_sent boolean := false;
  v_message_error text;
  v_gma_psid text;
  v_gma_message text;
  v_walkin boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (
    select 1 from public."StaffUsers"
    where "Username" = p_admin_username and "IsActive"
      and ("SuperUser" or 'ProductionManager' = any("StaffRoles"))
  ) then
    raise exception 'Only a Production Manager can assign orders.';
  end if;

  select "Status", "PreAssignStatus", "EstimatedDeliveryDate", coalesce("ReceivedAtShop", false)
    into v_status, v_pre_status, v_eta, v_walkin
  from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    raise exception 'Order % not found.', p_order_id;
  end if;

  v_status_key := lower(trim(coalesce(v_status, '')));
  v_complete := public._online_order_assignment_complete(p_order_id);
  v_target := case
    when v_status_key in ('confirmed', 'submitted', 'printed') and v_complete then 'Assigned'
    when v_status_key = 'assigned' and not v_complete then coalesce(nullif(trim(v_pre_status), ''), 'Confirmed')
    else null
  end;

  if v_target is null then
    return query select v_status, false, v_eta, false, null::text, null::text, null::text;
    return;
  end if;

  if v_target = 'Assigned' then
    v_payload := jsonb_build_object('status', public._online_order_assigned_pancake_code());

    -- Same rule as the POS print step: only when the order has no date yet.
    if v_eta is null then
      select t.thickness into v_thickness
      from (values ('12mm', 1), ('10mm', 2), ('6mm', 3), ('3mm', 4)) as t(thickness, priority)
      where exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id
          and regexp_replace(coalesce(ol."Description", '') || coalesce(ol."Note", '') || coalesce(ol."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%' || t.thickness || '%'
      )
      order by t.priority
      limit 1;

      if v_thickness is not null then
        select max(m[1]::int) into v_lead_days
        from public."GlassPricingSetup" g,
             regexp_matches(coalesce(g."TurnAroundDays", ''), '([0-9]+)', 'g') as m
        where regexp_replace(upper(coalesce(g."Thickness", '')), '[[:space:]]+', '', 'g')
              in (upper(v_thickness), regexp_replace(v_thickness, '[^0-9]', '', 'g'));

        if coalesce(v_lead_days, 0) > 0 then
          v_new_eta := (now() at time zone 'Asia/Manila')::date + v_lead_days;
          -- Midnight Manila as UTC, same format as the POS's FormatEstimatedDeliveryDateForEndpoint.
          v_payload := v_payload || jsonb_build_object('estimate_delivery_date',
            to_char((v_new_eta::timestamp at time zone 'Asia/Manila') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        end if;
      end if;
    end if;
  else
    v_payload := jsonb_build_object('status', case lower(v_target) when 'printed' then '13' else 'submitted' end);
  end if;

  perform public._pancake_patch_online_order_status(p_order_id, v_payload);

  update public."OnlineOrders"
  set "Status" = v_target,
      "PreAssignStatus" = case when v_target = 'Assigned' then v_status else null end,
      "EstimatedDeliveryDate" = coalesce(v_new_eta, "EstimatedDeliveryDate")
  where "OrderID" = p_order_id;

  -- First time Assigned: tell the customer it's in production (once per order, best-effort).
  -- WALK-IN: bought at the counter - no "in production" message.
  if v_target = 'Assigned' and not v_walkin and not exists (
    select 1 from public."OnlineOrderAssignedMessages" m where m."OrderID" = p_order_id and m."Sent"
  ) then
    -- Same GMA detection as admin_get_online_order_messaging_route (supabase_online_order_send_message.sql).
    select ao."GmaPsid" into v_gma_psid
    from public."AutomatedOrders" ao
    where ao."PancakeReceiptNo" = p_order_id
      and ao."GmaPsid" is not null
    limit 1;

    if v_gma_psid is not null then
      -- GMA Page order: the client sends it and logs the result (admin_record_online_order_assigned_message).
      v_gma_message := public._online_order_assigned_message_text(p_order_id);
    else
      begin
        perform public._send_online_order_assigned_message(p_order_id);
        v_message_sent := true;
      exception when others then
        v_message_error := sqlerrm;
      end;
      insert into public."OnlineOrderAssignedMessages" ("OrderID", "SentBy", "Sent", "Error")
      values (p_order_id, p_admin_username, v_message_sent, v_message_error)
      on conflict ("OrderID") do update
        set "SentAtUtc" = now(), "SentBy" = excluded."SentBy", "Sent" = excluded."Sent", "Error" = excluded."Error";
    end if;
  end if;

  return query select v_target, true, coalesce(v_new_eta, v_eta), v_message_sent, v_message_error, v_gma_psid, v_gma_message;
end;
$$;

grant execute on function public.admin_sync_online_order_assigned_status(text, text, text) to anon;

notify pgrst, 'reload schema';
