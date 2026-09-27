-- Real "Assigned" order status, pushed to Pancake - per "once the order has been assigned can we
-- moved that to the assigned status in the portal / treat it as packaging status in pancake too".
--
-- Pancake's own "Packing" (code 8) can't be used: this system already treats it as To Ship (the
-- desktop's MapStatusForApi pushes 8 for To Ship and every sync maps 'packing' back to To Ship),
-- so assigned orders would read back as To Ship. Per follow-up choice ("use another Pancake
-- status"), Assigned uses Pancake code 11 ("Restocking" / waiting for goods), which nothing here
-- used before. To use a different code, change _online_order_assigned_pancake_code() below and
-- the "Assigned" entry in the desktop's MapStatusForApi (OnlineOrdersForm.cs).
--
-- Per "my goal is in the local POS we will not print the order we will assign it on the portal
-- instead" - assigning replaces printing: Confirmed -> Assigned -> To Ship. Printed still works for
-- older orders (Printed -> Assigned too). ONLY for orders with a custom line ("custom" in a line's
-- item code/description) - normal orders keep going through the local POS (print -> To Ship).
--   - Saving the Assign popup calls admin_sync_online_order_assigned_status, which moves a
--     Confirmed (or Printed) order to 'Assigned' (Pancake 11) once every needed role is set (Tank
--     for a custom aquarium line, Stand for a custom stand line; an order needing neither needs a
--     Dispatcher). Clearing a role moves it back to whatever it was before (PreAssignStatus).
--   - Takes over the print step's Estimated Delivery Date (OnlineOrdersForm.cs's
--     UpdateEstimatedDeliveryDateForPrintedOrder): if the order has none yet, today + the turnaround
--     days of its thickest glass (12mm > 10mm > 6mm > 3mm in its lines), sent to Pancake with the
--     status. Turnaround days lived only in the POS's local GlassPricingSetup, so this adds a
--     "TurnAroundDays" column to Supabase's GlassPricingSetup - fill it in (see the end of this
--     file); until then no date is set.
--   - A trigger on OnlineOrders turns whatever raw token the Pancake sync writes for code 11 back
--     into 'Assigned', so the next sync pass doesn't undo it.
--   - admin_list_online_orders / admin_get_online_order_status_summary count a real 'Assigned'
--     status (the old Printed-derived rule still applies too), and To Ship is allowed from
--     'Assigned' as well as 'Printed' (admin_update_online_order_status).
--
-- Run AFTER supabase_production_manager_role.sql. Re-creates the functions below from their current
-- versions in supabase_orders_sync_tables.sql / supabase_online_order_portal_status_update.sql.

-- The every-minute Pancake sync writes OnlineOrders while this runs; altering the table / adding
-- the trigger mid-way hit "40P01: deadlock detected". Taking both table locks first, in one go,
-- makes this wait for the sync pass to finish instead of deadlocking with it.
begin;
set local lock_timeout = '30s';
lock table public."OnlineOrders", public."GlassPricingSetup" in access exclusive mode;

alter table public."OnlineOrders" add column if not exists "PreAssignStatus" text;
alter table public."GlassPricingSetup" add column if not exists "TurnAroundDays" text;

create or replace function public._online_order_assigned_pancake_code()
returns text language sql immutable as $$ select '11'::text $$;

-- ---------------------------------------------------------------------------
-- Normalise the synced status: Pancake's token for code 11 -> 'Assigned'.
create or replace function public._normalize_online_order_status()
returns trigger
language plpgsql
as $$
begin
  if lower(trim(coalesce(new."Status", ''))) in (
    public._online_order_assigned_pancake_code(), 'assigned', 'restocking', 'waitting', 'waiting_for_goods', 'waiting for goods', 'wait_goods'
  ) then
    new."Status" := 'Assigned';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_online_orders_normalize_status on public."OnlineOrders";
create trigger trg_online_orders_normalize_status
  before insert or update of "Status" on public."OnlineOrders"
  for each row execute function public._normalize_online_order_status();

-- ---------------------------------------------------------------------------
-- Is every needed role on this order filled?
create or replace function public._online_order_assignment_complete(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with o as (
    select
      nullif(trim(coalesce("AssignedTankMaker", '')), '') as tank,
      nullif(trim(coalesce("AssignedStandMaker", '')), '') as stand,
      nullif(trim(coalesce("AssignedDispatcher", '')), '') as dispatcher,
      exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id
          and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
          and (ol."Description" ilike '%aquarium%' or ol."ItemCode" ilike '%aquarium%')
      ) as needs_tank,
      exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id
          and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
          and (ol."Description" ilike '%stand%' or ol."ItemCode" ilike '%stand%')
      ) as needs_stand,
      exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id
          and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
      ) as has_custom
    from public."OnlineOrders"
    where "OrderID" = p_order_id
  )
  -- Per "the confirmed > assigned > to-ship process will only apply to orders with custom items.
  -- for normal it will still go through to local pos" - an order with no custom line is never
  -- "complete", so its status is never moved here (a Dispatcher can still be recorded on it).
  select coalesce((
    select case
      when not has_custom then false
      when needs_tank or needs_stand then (not needs_tank or tank is not null) and (not needs_stand or stand is not null)
      else dispatcher is not null
    end
    from o
  ), false);
$$;

-- ---------------------------------------------------------------------------
-- PATCH an order in Pancake (status and/or estimate_delivery_date), keeping bank_payments (same snapshot/restore workaround and
-- retry as admin_update_online_order_status - Pancake's PATCH wipes bank_payments otherwise).
drop function if exists public._pancake_patch_online_order_status(text, text);

create or replace function public._pancake_patch_online_order_status(p_order_id text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id
    || '?api_key=' || public._pancake_api_key() || '&page_size=1000';
  v_get_response extensions.http_response;
  v_get_body jsonb;
  v_order_obj jsonb;
  v_bank_payments jsonb;
  v_patch_response extensions.http_response;
  v_attempt int := 0;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  begin
    select * into v_get_response from extensions.http_get(v_order_url);
    if v_get_response.status >= 200 and v_get_response.status < 300 then
      v_get_body := v_get_response.content::jsonb;
      v_order_obj := case
        when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
        when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
        else v_get_body
      end;
      if jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then
        v_bank_payments := v_order_obj -> 'bank_payments';
      end if;
    end if;
  exception when others then
    v_bank_payments := null;
  end;

  loop
    v_attempt := v_attempt + 1;
    begin
      select * into v_patch_response from extensions.http((
        'PATCH', v_order_url,
        array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
        'application/json',
        p_payload::text
      )::extensions.http_request);
      exit;
    exception when others then
      if v_attempt >= 2 then raise; end if;
    end;
  end loop;

  if v_patch_response.status < 200 or v_patch_response.status >= 300 then
    raise exception 'Pancake rejected the status update (HTTP %).', v_patch_response.status;
  end if;

  if v_bank_payments is not null then
    begin
      perform extensions.http((
        'PATCH', v_order_url,
        array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
        'application/json',
        jsonb_build_object('bank_payments', v_bank_payments)::text
      )::extensions.http_request);
    exception when others then
      null;
    end;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Called by the portal after the Assign popup saves. Confirmed/Printed + fully assigned -> Assigned;
-- Assigned + no longer fully assigned -> back to PreAssignStatus. Any other status is left alone
-- (To Ship and later never move back).
drop function if exists public.admin_sync_online_order_assigned_status(text, text, text);

create or replace function public.admin_sync_online_order_assigned_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(new_status text, changed boolean, estimated_delivery_date date)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '45000'
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

  select "Status", "PreAssignStatus", "EstimatedDeliveryDate" into v_status, v_pre_status, v_eta
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
    return query select v_status, false, v_eta;
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

  return query select v_target, true, coalesce(v_new_eta, v_eta);
end;
$$;

grant execute on function public.admin_sync_online_order_assigned_status(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Re-created from supabase_orders_sync_tables.sql: 'Assigned' filter also matches the real status.
drop function if exists public.admin_list_online_orders(text, text, text, text);
drop function if exists public.admin_list_online_orders(text, text, text, text, text);
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean);
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int);
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text);
-- Also drop the p_status_in-only overload from supabase_online_order_staff_status_scope.sql - its
-- return table (no has_custom_line/assigned_production_member/is_gma_order/gma_order_no) differs
-- from this file's, so a plain create-or-replace onto that signature would fail. p_status_in is
-- folded into THIS function below instead, so there's only ever one admin_list_online_orders again.
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text, text[]);

-- p_order_id: exact filter, used by the lines drill-down page to fetch just that order's header.
-- p_search/p_status: free-text browsing filters, ignored when p_order_id is set.
--
-- glass_thickness: per "put a flag in the online header to show if an order has 10mm glass or
-- 12mm glass custom aquarium it may need or require an attachment". Straight passthrough of the
-- cached OnlineOrders."GlassThickness" column - see that column's comment above (near the
-- ReceivedAtShop alter) for how/where it actually gets computed and cached. Deliberately NOT
-- computed here from OnlineOrderLines/live Pancake, so this stays a plain instant read with no
-- per-row lookup cost at page-load time.
--
-- has_custom_line: per "assign the order to a team member" for custom-built items (custom
-- aquarium/stand/sump/etc, identified the same way as everywhere else in this codebase - the
-- word "custom" in the line's item code/description, see supabase_online_order_production_
-- assignment.sql's header comment). Unlike glass_thickness above, this is computed live via a
-- correlated EXISTS against OnlineOrderLines rather than cached on the row - OnlineOrderLines is
-- already a locally-synced table (no live Pancake call needed to check it), so there's no reason
-- to pay for a separate cache/backfill job here.
--
-- assigned_production_member / assigned_production_member_name: the Production Member (see
-- supabase_staff_users_production_member_field.sql) this order's custom build is assigned to, if
-- any - set via admin_assign_online_order_production_member
-- (supabase_online_order_production_assignment.sql).
--
-- p_period / p_walkin_only: per "once I click the dashboard I want to be able to open the
-- corresponding data/page of entries filtered" - the dashboard's finance cards (Total Sales This
-- Month, Today's Online Sales, Walk-In Sales This Month, Today's Walk-In Sales) link here with
-- these set so the list opens already scoped to what the card showed, instead of the full
-- unfiltered order list. p_period ('month'/'today'/'prevmonth'/null) reuses the exact same
-- Asia/Manila boundary logic as admin_get_online_order_financial_summary/admin_get_sales_by_
-- confirmed_by so the list always matches what that card actually counted. p_walkin_only flips
-- the existing ReceivedAtShop exclusion around (default false preserves the page's normal
-- online-orders-only behavior).
--
-- p_confirmed_by: per "click on the [Sales by Staff] figure and show all order details" - an
-- exact (case/whitespace-insensitive) match against OnlineOrders."ConfirmedBy", used by the
-- Dashboard's Sales by Staff cards to deep-link straight to that staff member's orders for the
-- period clicked. Same text-match convention as admin_get_sales_by_confirmed_by.
--
-- p_page/p_page_size (portal-wide pagination): total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
create or replace function public.admin_list_online_orders(
  p_admin_username text, p_admin_password text,
  p_search text default null, p_status text default null, p_order_id text default null,
  p_period text default null, p_walkin_only boolean default false,
  p_page int default 1, p_page_size int default 50,
  p_confirmed_by text default null,
  -- p_status_in (folded back in from supabase_online_order_staff_status_scope.sql, see the drop
  -- comment above): Online Order Staff's exact-match Confirmed/Printed/To Ship lock. Takes over
  -- filtering entirely when provided; p_status is ignored (same contract as that file described).
  p_status_in text[] default null
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
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

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
               and (ol."Description" ilike '%aquarium%' or ol."ItemCode" ilike '%aquarium%')
           ),
           exists (
             select 1 from public."OnlineOrderLines" ol
             where ol."OrderID" = o."OrderID"
               and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
               and (ol."Description" ilike '%stand%' or ol."ItemCode" ilike '%stand%')
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
    where (case when p_walkin_only then o."ReceivedAtShop" is true else o."ReceivedAtShop" is not true end)
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
              when p_status is not null and lower(trim(p_status)) = 'assigned' then
                lower(trim(coalesce(o."Status", ''))) = 'assigned'
                or (o."Status" ilike '%printed%'
                and exists (
                  select 1 from public."OnlineOrderLines" ol
                  where ol."OrderID" = o."OrderID"
                    and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
                    and ((ol."Description" ilike '%aquarium%' or ol."ItemCode" ilike '%aquarium%')
                      or (ol."Description" ilike '%stand%' or ol."ItemCode" ilike '%stand%'))
                )
                and (
                  not exists (
                    select 1 from public."OnlineOrderLines" ol
                    where ol."OrderID" = o."OrderID"
                      and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
                      and (ol."Description" ilike '%aquarium%' or ol."ItemCode" ilike '%aquarium%')
                  )
                  or (o."AssignedTankMaker" is not null and trim(o."AssignedTankMaker") <> '')
                )
                and (
                  not exists (
                    select 1 from public."OnlineOrderLines" ol
                    where ol."OrderID" = o."OrderID"
                      and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
                      and (ol."Description" ilike '%stand%' or ol."ItemCode" ilike '%stand%')
                  )
                  or (o."AssignedStandMaker" is not null and trim(o."AssignedStandMaker") <> '')
                ))
              else (p_status is null or trim(p_status) = '' or o."Status" ilike '%' || p_status || '%')
            end
          )
        )
      )
    order by o."Last_Updated_At" desc nulls last, o."Date" desc nulls last
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- Re-created from supabase_orders_sync_tables.sql: real 'Assigned' status counts as Assigned.
drop function if exists public.admin_get_online_order_status_summary(text, text);
drop function if exists public.admin_get_online_order_status_summary(text, text, text);

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
      values ('Confirmed', 1), ('Printed', 2), ('Assigned', 3), ('To Ship', 4), ('Shipped', 5), ('Cancelled', 6)
    ),
    order_flags as (
      select
        o.*,
        exists (
          select 1 from public."OnlineOrderLines" ol
          where ol."OrderID" = o."OrderID"
            and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
            and (ol."Description" ilike '%aquarium%' or ol."ItemCode" ilike '%aquarium%')
        ) as needs_tank,
        exists (
          select 1 from public."OnlineOrderLines" ol
          where ol."OrderID" = o."OrderID"
            and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
            and (ol."Description" ilike '%stand%' or ol."ItemCode" ilike '%stand%')
        ) as needs_stand
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where o."ReceivedAtShop" is not true
        and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name)
    ),
    order_buckets as (
      select
        case
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

-- ---------------------------------------------------------------------------
-- Re-created from supabase_online_order_portal_status_update.sql: To Ship allowed from Assigned.
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean);
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean, text);
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean, text, text);
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean, text, text, bigint[]);
drop function if exists public.admin_update_online_order_status(text, text, text, text, boolean, bigint[]);

-- Per direct instruction, the photo send is now a SEPARATE call the client makes on its own
-- (see admin_send_online_order_status_photo below) rather than bundled into this function - this
-- used to chain a status PATCH + bank_payments snapshot/restore + text message + photo POST all
-- inside one request, which was long enough to occasionally hit the authenticator role's
-- statement_timeout ("canceling statement due to statement timeout"). Splitting the photo out
-- shortens this function's own worst-case runtime and means a slow/failing photo attach can never
-- roll back the actual status change.
create or replace function public.admin_update_online_order_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_new_status text,
  p_notify_customer boolean default false,
  p_serial_running_nos bigint[] default null
)
returns table(new_status text, message_sent boolean, message_error text)
language plpgsql
security definer
set search_path = public, extensions
-- Overrides whatever statement_timeout the authenticator role happens to have (previously seen
-- hitting Postgres's default ~8s and killing this mid-flight - "canceling statement due to
-- statement timeout" - since this chains a GET + PATCH + PATCH, each with its own retry). Set
-- directly on the function so it's guaranteed regardless of role/session config.
set statement_timeout = '45000'
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
        where "RunningSerialNo" = any(p_serial_running_nos) and "Status" = 'IN_STOCK'
        returning "RunningSerialNo"
    )
    select count(*) into v_claimed_serial_count from claimed;

    if v_claimed_serial_count < v_requested_serial_count then
      raise exception 'Only % of % selected serial(s) were still available - someone may have just claimed one. Refresh and try again.', v_claimed_serial_count, v_requested_serial_count;
    end if;
  end if;

  v_api_token := '8'; -- MapStatusForApi's token for 'To Ship'

  v_order_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || p_order_id || '?api_key=' || v_api_key || '&page_size=1000';

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  -- Snapshot bank_payments before the status PATCH - see file header for why.
  begin
    select * into v_get_response from extensions.http_get(v_order_url);
    if v_get_response.status >= 200 and v_get_response.status < 300 then
      v_get_body := v_get_response.content::jsonb;
      v_order_obj := case
        when jsonb_typeof(v_get_body -> 'data') = 'object' then v_get_body -> 'data'
        when jsonb_typeof(v_get_body -> 'order') = 'object' then v_get_body -> 'order'
        else v_get_body
      end;
      if jsonb_typeof(v_order_obj -> 'bank_payments') = 'object' then
        v_bank_payments := v_order_obj -> 'bank_payments';
      end if;
    end if;
  exception when others then
    v_bank_payments := null; -- best-effort, same as the C# GetBankPaymentsSnapshotAsync
  end;

  -- Header set matches the one proven working elsewhere in this codebase for Pancake writes (see
  -- _push_automated_order_to_pancake's comment) - 'Expect: ' suppresses libcurl's automatic
  -- "Expect: 100-continue" header, which Pancake's side has been observed to mishandle.
  --
  -- Retried once on a connection-level failure (e.g. "OpenSSL SSL_read: SSL_ERROR_SYSCALL, errno
  -- 0" - a dropped/stale reused connection, not a rejection from Pancake) - this was previously
  -- unguarded, so a single transient network hiccup failed the whole To Ship action outright. Safe
  -- to retry: PATCHing the same target status twice is idempotent, not a duplicate action. Does
  -- NOT retry a legitimate non-2xx response from Pancake (e.g. a real rejection) - only an
  -- exception raised by the HTTP call itself triggers the retry.
  v_patch_attempt := 0;
  loop
    v_patch_attempt := v_patch_attempt + 1;
    begin
      select * into v_patch_response from extensions.http((
        'PATCH',
        v_order_url,
        array[
          extensions.http_header('Accept', 'application/json'),
          extensions.http_header('Expect', '')
        ],
        'application/json',
        jsonb_build_object('status', v_api_token)::text
      )::extensions.http_request);
      exit;
    exception when others then
      if v_patch_attempt >= 2 then
        raise;
      end if;
    end;
  end loop;

  if v_patch_response.status < 200 or v_patch_response.status >= 300 then
    raise exception 'Pancake rejected the status update (HTTP %).', v_patch_response.status;
  end if;

  -- Restore bank_payments after a successful status PATCH - best-effort, never blocks the status
  -- change itself, matching RestoreBankPaymentsAsync's own contract.
  if v_bank_payments is not null then
    begin
      perform extensions.http((
        'PATCH',
        v_order_url,
        array[
          extensions.http_header('Accept', 'application/json'),
          extensions.http_header('Expect', '')
        ],
        'application/json',
        jsonb_build_object('bank_payments', v_bank_payments)::text
      )::extensions.http_request);
    exception when others then
      null;
    end;
  end if;

  -- Reflects immediately in the portal without waiting for the next cron sync pass - harmless even
  -- though OnlineOrders is normally a Pancake -> Supabase mirror, since this is exactly the value
  -- Pancake now actually has.
  update public."OnlineOrders" set "Status" = p_new_status where "OrderID" = p_order_id;

  if p_notify_customer then
    begin
      perform public._send_online_order_status_message(p_order_id, p_new_status);
      v_message_sent := true;
    exception when others then
      v_message_error := sqlerrm;
    end;
  end if;

  return query select p_new_status, v_message_sent, v_message_error;
end;
$$;

grant execute on function public.admin_update_online_order_status(text, text, text, text, boolean, bigint[]) to anon;

commit;

-- ---------------------------------------------------------------------------
-- Fill in the glass turnaround days (copy them from the POS: Glass Pricing Setup's Turn Around Days).
-- Until these are set, assigning an order doesn't set an Estimated Delivery Date. Example (replace
-- the numbers with yours, then uncomment):
--   update public."GlassPricingSetup" set "TurnAroundDays" = '3' where "Thickness" ilike '3%';
--   update public."GlassPricingSetup" set "TurnAroundDays" = '5' where "Thickness" ilike '6%';
--   update public."GlassPricingSetup" set "TurnAroundDays" = '7' where "Thickness" ilike '10%';
--   update public."GlassPricingSetup" set "TurnAroundDays" = '10' where "Thickness" ilike '12%';
