-- Which maker builds which custom line - per "all custom without STAND and TOPCOVER will fall under
-- Tank maker / all CUSTOM-STAND and CUSTOM-TOPCOVER will fall under stand maker".
--
-- Before: only a custom line mentioning "aquarium" needed a Tank Maker and one mentioning "stand" a
-- Stand Maker; any other custom line (CUSTOM-TOPCOVER, "Custom", "All-Custom-Item", sumps...) had no
-- maker at all. Now every custom line has one:
--   - name/item code mentions "stand" or "top cover" (topcover, top-cover, top cover) -> Stand Maker
--   - every other custom line                                                   -> Tank Maker
-- "Custom" = name, item code or product id contains "custom" (unchanged). Non-custom lines still need
-- no maker, so an order with no custom line still follows the POS.
--
-- One shared rule, _online_order_line_part(), now drives:
--   - _online_order_production_roles (Production Done parts, My Assignments, "assignment complete")
--   - admin_list_online_orders' has_aquarium_line / has_stand_line (Assign popup, order card, list)
--     and its Assigned filter - has_aquarium_line now means "needs a Tank Maker"
--   - admin_get_online_order_status_summary's Assigned counts
-- The Glass Cut section still only reads custom *aquarium* lines (it needs tank dimensions).
--
-- Run AFTER supabase_online_order_dispatcher_on_ship.sql and supabase_online_order_production_done_tab.sql
-- (re-creates functions from them). Functions only - no table locks.

create or replace function public._online_order_line_part(p_description text, p_item_code text, p_product_display_id text)
returns text
language sql
immutable
as $$
  select case
    when not (coalesce(p_description, '') ilike '%custom%' or coalesce(p_item_code, '') ilike '%custom%'
              or coalesce(p_product_display_id, '') ilike '%custom%') then null
    when (coalesce(p_description, '') || ' ' || coalesce(p_item_code, '')) ~* '(stand|top[[:space:]_-]*cover)' then 'stand'
    else 'tank'
  end;
$$;

revoke execute on function public._online_order_line_part(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
create or replace function public._online_order_production_roles(p_order_id text)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select
    (case when exists (
      select 1 from public."OnlineOrderLines" ol
      where ol."OrderID" = p_order_id and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'tank'
    ) then array['tank'] else array[]::text[] end)
    || (case when exists (
      select 1 from public."OnlineOrderLines" ol
      where ol."OrderID" = p_order_id and public._online_order_line_part(ol."Description", ol."ItemCode", ol."product_display_id") = 'stand'
    ) then array['stand'] else array[]::text[] end);
$$;

revoke execute on function public._online_order_production_roles(text) from public, anon, authenticated;

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
      and (case when p_walkin_only then o."ReceivedAtShop" is true else o."ReceivedAtShop" is not true end)
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
create or replace function public.admin_get_online_order_status_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null)
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

grant execute on function public.admin_get_online_order_status_summary(text, text, text) to anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- CHECK (run on its own): which maker each line of an order needs.
-- select l."ItemCode", l."Description", public._online_order_line_part(l."Description", l."ItemCode", l."product_display_id") as maker_part
-- from public."OnlineOrderLines" l where l."OrderID" = '103949';
