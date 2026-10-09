-- Advance Order production / assignment - per "in the advance order tab i want to see the assigning
-- process end to end so i can assign the advance order too".
--
-- Advance orders are POS-owned (dbo.AdvanceOrderHeader -> public."AdvanceOrders", re-upserted by the
-- POS every 5 minutes) and most have no Pancake/online order behind them, so the online-order flow
-- can't be reused as-is. This adds the SAME process, portal-owned, in its own table (the POS sync never
-- touches it):
--
--   (new) -> Assigned -> Production Done -> To Ship -> Shipped
--
--   * Assign (Super User / Production Manager): Tank Maker and/or Stand Maker - each must hold that
--     Staff Role, same as online orders. Lines suggest which parts are needed (_online_order_line_part:
--     "custom" lines, stands/top covers -> Stand Maker), but either maker can be set on any order.
--     The maker gets a "New tank/stand job assigned" push (_trigger_web_push, targeted).
--   * Production Done: the assigned maker (or a manager) marks their part done from My Assignments.
--     Status becomes Production Done once every ASSIGNED part is done.
--   * Send Back (manager): un-does one part with a reason, logged in AdvanceOrderRework; the maker
--     sees the reason on their card. Marking the part done again closes the rework entry.
--   * To Ship (manager): once production is done (or no makers were needed). Shipped (manager): ends
--     it - the order leaves the makers' lists. Both can be undone by setting the stage back.
--
-- The list (admin_list_advance_orders) is also opened up to Production Managers (was Super User only),
-- since assigning is their job. This file SUPERSEDES supabase_advance_orders_assignment.sql and
-- supabase_advance_orders_sort_latest_update.sql (same latest-update sort is kept) - don't run either
-- of those after this one.
--
-- WARNING: re-running this AFTER supabase_online_orders_list_sort.sql adds back an old admin_list_advance_orders
-- next to the sort version (Advance Orders tab: "Could not choose the best candidate function") - run
-- supabase_advance_orders_drop_old_list_overload.sql afterwards if you do.
-- Run AFTER supabase_production_orders.sql (_production_is_manager), supabase_online_order_plywood_no_maker.sql
-- (_online_order_line_part) and supabase_web_push_targeted.sql (_trigger_web_push). Safe to re-run.

-- ============================================================================
-- 1. Tables (portal-owned; RLS on, no direct access - RPCs only)
-- ============================================================================

create table if not exists public."AdvanceOrderProduction" (
  "TransactionNo" varchar(100) primary key,
  "TankMaker" text,
  "StandMaker" text,
  "TankDoneAtUtc" timestamptz,
  "TankDoneBy" text,
  "StandDoneAtUtc" timestamptz,
  "StandDoneBy" text,
  "ToShipAtUtc" timestamptz,
  "ToShipBy" text,
  "ShippedAtUtc" timestamptz,
  "ShippedBy" text,
  "AssignedAtUtc" timestamptz,
  "AssignedBy" text,
  "UpdatedAtUtc" timestamptz not null default now(),
  "UpdatedBy" text
);

create index if not exists "IX_AdvanceOrderProduction_TankMaker" on public."AdvanceOrderProduction" ("TankMaker");
create index if not exists "IX_AdvanceOrderProduction_StandMaker" on public."AdvanceOrderProduction" ("StandMaker");

create table if not exists public."AdvanceOrderRework" (
  "Id" bigint generated always as identity primary key,
  "TransactionNo" varchar(100) not null,
  "Part" text not null check ("Part" in ('tank', 'stand')),
  "Reason" text,
  "WasDoneBy" text,
  "SentBackBy" text,
  "SentBackAtUtc" timestamptz not null default now(),
  "FixedAtUtc" timestamptz
);

create index if not exists "IX_AdvanceOrderRework_Order" on public."AdvanceOrderRework" ("TransactionNo");

alter table public."AdvanceOrderProduction" enable row level security;
alter table public."AdvanceOrderRework" enable row level security;
revoke all on public."AdvanceOrderProduction" from anon, authenticated;
revoke all on public."AdvanceOrderRework" from anon, authenticated;

-- ============================================================================
-- 2. Helpers (internal)
-- ============================================================================

-- (new) / Assigned / Production Done / To Ship / Shipped - from the production row (null = never assigned).
create or replace function public._advance_order_prod_status(p public."AdvanceOrderProduction")
returns text
language sql
immutable
as $$
  select case
    when p."ShippedAtUtc" is not null then 'Shipped'
    when p."ToShipAtUtc" is not null then 'To Ship'
    when p."TankMaker" is null and p."StandMaker" is null then null
    when (p."TankMaker" is not null and p."TankDoneAtUtc" is null)
      or (p."StandMaker" is not null and p."StandDoneAtUtc" is null) then 'Assigned'
    else 'Production Done'
  end;
$$;

revoke execute on function public._advance_order_prod_status(public."AdvanceOrderProduction") from public, anon, authenticated;

-- Which maker parts the order's lines suggest (same rule as online orders).
create or replace function public._advance_order_needs(p_no text, out needs_tank boolean, out needs_stand boolean)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(bool_or(public._online_order_line_part(l."Description", l."No", null) = 'tank'), false),
         coalesce(bool_or(public._online_order_line_part(l."Description", l."No", null) = 'stand'), false)
  from public."AdvanceOrderLines" l
  where l."TransactionNo" = p_no;
$$;

revoke execute on function public._advance_order_needs(text) from public, anon, authenticated;

-- The POS's free-text "Time" as a time, or null. Only real clock values are cast (00-23 hours, or
-- 1-12 with am/pm; 00-59 minutes/seconds), so a typo like '25:70' or '13:00 PM' can never make the
-- cast - and with it the whole Advance Orders list - fail.
create or replace function public._advance_order_time(p_time text)
returns time
language sql
immutable
as $$
  select case
    when t ~ '^([01]?\d|2[0-3]):[0-5]\d(:[0-5]\d)?(\.\d+)?$'
      or t ~* '^(0?[1-9]|1[0-2]):[0-5]\d(:[0-5]\d)?(\.\d+)?\s*[ap]m$' then t::time
  end
  from (select trim(coalesce(p_time, '')) as t) x;
$$;

revoke execute on function public._advance_order_time(text) from public, anon, authenticated;

-- ============================================================================
-- 3. List (Advance Orders tab) - Super User or Production Manager
-- ============================================================================

drop function if exists public.admin_list_advance_orders(text, text, text, text, int, int);
drop function if exists public.admin_list_advance_orders(text, text, text, text, int, int, text);

-- p_prod_status: null = all, 'New' = never assigned, or Assigned / Production Done / To Ship / Shipped.
create or replace function public.admin_list_advance_orders(
  p_admin_username text, p_admin_password text,
  p_search text default null, p_transaction_no text default null,
  p_page int default 1, p_page_size int default 50,
  p_prod_status text default null
)
returns table(
  transaction_no text,
  receipt_no text,
  user_id text,
  customer_name text,
  order_description text,
  order_date date,
  order_time text,
  net_amount numeric,
  downpayment numeric,
  balance numeric,
  online_order_id text,
  fully_paid boolean,
  date_paid timestamptz,
  warehouse text,
  synced_at_utc timestamptz,
  prod_status text,             -- null = not assigned yet
  tank_maker text,
  tank_maker_name text,
  stand_maker text,
  stand_maker_name text,
  tank_done_at timestamptz,
  stand_done_at timestamptz,
  to_ship_at timestamptz,
  to_ship_by text,
  shipped_at timestamptz,
  shipped_by text,
  needs_tank boolean,
  needs_stand boolean,
  open_rework_count int,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_status text := nullif(trim(coalesce(p_prod_status, '')), '');
begin
  if not (public.is_admin_authorized(p_admin_username, p_admin_password)
          or (public.is_staff_authorized(p_admin_username, p_admin_password) and public._production_is_manager(p_admin_username))) then
    raise exception 'Not authorized.';
  end if;

  -- Filter + sort + page first (cheap columns only), then work out the per-order extras (which makers
  -- the lines suggest, open rework, maker names) for just the rows on this page.
  return query
    with base as (
      select a.*, p as prod, public._advance_order_prod_status(p) as status,
             -- Latest activity: the later of when it was fully paid ("DatePaid") and when it was placed
             -- ("Date" + "Time", Manila; a "Time" that isn't a clock value counts as midnight).
             greatest(a."DatePaid",
                      (a."Date" + coalesce(public._advance_order_time(a."Time"), time '00:00')) at time zone 'Asia/Manila') as last_update
      from public."AdvanceOrders" a
      left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
    ),
    page as (
      select b.*, count(*) over() as total
      from base b
      where ((p_transaction_no is not null and trim(p_transaction_no) <> '' and b."TransactionNo" = p_transaction_no)
         or (
           (p_transaction_no is null or trim(p_transaction_no) = '')
           and (
             p_search is null or trim(p_search) = ''
             or b."TransactionNo" ilike '%' || p_search || '%'
             or b."ReceiptNo" ilike '%' || p_search || '%'
             or b."CustomerName" ilike '%' || p_search || '%'
             or b."UserID" ilike '%' || p_search || '%'
             or b."OnlineOrderID" ilike '%' || p_search || '%'
           )
         ))
        and (v_status is null
             or (v_status = 'New' and b.status is null)
             or b.status = v_status)
      order by b.last_update desc nulls last,
               case when b."TransactionNo" ~ '^\d+$' then b."TransactionNo"::numeric end desc nulls last,
               b."TransactionNo" desc
      limit v_page_size offset (v_page - 1) * v_page_size
    )
    select pg."TransactionNo"::text, pg."ReceiptNo"::text, pg."UserID"::text, pg."CustomerName"::text, pg."Order_Description"::text,
           pg."Date", pg."Time"::text, pg."NetAmount", pg."Downpayment", pg."Balance",
           pg."OnlineOrderID"::text,
           coalesce(pg."FullyPaid", false) or coalesce(pg."Balance", 0) <= 0,
           pg."DatePaid", pg."Warehouse"::text, pg."SyncedAtUtc",
           pg.status,
           (pg.prod)."TankMaker", tank."DisplayName"::text,
           (pg.prod)."StandMaker", stand."DisplayName"::text,
           (pg.prod)."TankDoneAtUtc", (pg.prod)."StandDoneAtUtc",
           (pg.prod)."ToShipAtUtc", (pg.prod)."ToShipBy",
           (pg.prod)."ShippedAtUtc", (pg.prod)."ShippedBy",
           n.needs_tank, n.needs_stand,
           (select count(*)::int from public."AdvanceOrderRework" r where r."TransactionNo" = pg."TransactionNo" and r."FixedAtUtc" is null),
           pg.total
    from page pg
    cross join lateral public._advance_order_needs(pg."TransactionNo") n
    left join public."StaffUsers" tank on tank."Username" = (pg.prod)."TankMaker"
    left join public."StaffUsers" stand on stand."Username" = (pg.prod)."StandMaker"
    order by pg.last_update desc nulls last,
             case when pg."TransactionNo" ~ '^\d+$' then pg."TransactionNo"::numeric end desc nulls last,
             pg."TransactionNo" desc;
end;
$$;

grant execute on function public.admin_list_advance_orders(text, text, text, text, int, int, text) to anon;

-- Counts per stage for the tab's status pills.
create or replace function public.staff_get_advance_order_status_summary(p_admin_username text, p_admin_password text)
returns table(status text, order_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not (public.is_admin_authorized(p_admin_username, p_admin_password)
          or (public.is_staff_authorized(p_admin_username, p_admin_password) and public._production_is_manager(p_admin_username))) then
    raise exception 'Not authorized.';
  end if;
  return query
    select coalesce(public._advance_order_prod_status(p), 'New'), count(*)
    from public."AdvanceOrders" a
    left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
    group by 1;
end;
$$;

grant execute on function public.staff_get_advance_order_status_summary(text, text) to anon;

-- ============================================================================
-- 4. Lines + rework history - managers, or a maker assigned to that order
-- ============================================================================

create or replace function public._advance_order_can_view(p_username text, p_no text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._production_is_manager(p_username)
      or exists (select 1 from public."StaffUsers" where "Username" = p_username and "IsActive" and "SuperUser")
      or exists (select 1 from public."AdvanceOrderProduction" p
                 where p."TransactionNo" = p_no and p_username in (p."TankMaker", p."StandMaker"));
$$;

revoke execute on function public._advance_order_can_view(text, text) from public, anon, authenticated;

create or replace function public.staff_list_advance_order_lines(p_admin_username text, p_admin_password text, p_no text)
returns table(
  line_no text, type text, item_no text, description text, quantity numeric,
  price numeric, discount numeric, gross_amount numeric, net_amount numeric, part text
)
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
    select l."LineNo"::text, l."Type"::text, l."No"::text, l."Description"::text, l."Quantity",
           l."Price", l."Discount", l."GrossAmount", l."NetAmount",
           public._online_order_line_part(l."Description", l."No", null)
    from public."AdvanceOrderLines" l
    where l."TransactionNo" = p_no
    order by case when l."LineNo" ~ '^\d+$' then l."LineNo"::numeric end nulls last, l."LineNo";
end;
$$;

grant execute on function public.staff_list_advance_order_lines(text, text, text) to anon;

create or replace function public.staff_list_advance_order_rework(p_admin_username text, p_admin_password text, p_no text)
returns table(id bigint, part text, reason text, was_done_by text, sent_back_by text, sent_back_at timestamptz, fixed_at timestamptz)
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
    select r."Id", r."Part", r."Reason", r."WasDoneBy", r."SentBackBy", r."SentBackAtUtc", r."FixedAtUtc"
    from public."AdvanceOrderRework" r
    where r."TransactionNo" = p_no
    order by r."SentBackAtUtc" desc;
end;
$$;

grant execute on function public.staff_list_advance_order_rework(text, text, text) to anon;

-- ============================================================================
-- 5. Actions
-- ============================================================================

-- p_role 'tank' | 'stand'; p_username null clears it. Changing the maker resets that part's done mark.
create or replace function public.staff_assign_advance_order_maker(
  p_admin_username text, p_admin_password text, p_no text, p_role text, p_username text
)
returns text   -- the order's new status
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_role text := lower(trim(coalesce(p_role, '')));
  v_user text := nullif(trim(coalesce(p_username, '')), '');
  v_prod public."AdvanceOrderProduction";
  v_old text;
  v_customer text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can assign makers.';
  end if;
  if v_role not in ('tank', 'stand') then
    raise exception 'p_role must be ''tank'' or ''stand''.';
  end if;
  select "CustomerName" into v_customer from public."AdvanceOrders" where "TransactionNo" = p_no;
  if not found then
    raise exception 'Advance order % not found.', p_no;
  end if;
  if v_user is not null and not exists (
       select 1 from public."StaffUsers" where "Username" = v_user and "IsActive"
         and (case v_role when 'tank' then 'TankMaker' else 'StandMaker' end) = any(coalesce("StaffRoles", '{}'))) then
    raise exception '% is not an active % Maker.', v_user, initcap(v_role);
  end if;

  insert into public."AdvanceOrderProduction" ("TransactionNo") values (p_no) on conflict do nothing;
  select * into v_prod from public."AdvanceOrderProduction" where "TransactionNo" = p_no for update;
  if v_prod."ShippedAtUtc" is not null then
    raise exception 'Advance order % is already Shipped.', p_no;
  end if;

  v_old := case v_role when 'tank' then v_prod."TankMaker" else v_prod."StandMaker" end;
  if v_old is not distinct from v_user then
    return public._advance_order_prod_status(v_prod);
  end if;

  if v_role = 'tank' then
    update public."AdvanceOrderProduction"
       set "TankMaker" = v_user, "TankDoneAtUtc" = null, "TankDoneBy" = null
     where "TransactionNo" = p_no;
  else
    update public."AdvanceOrderProduction"
       set "StandMaker" = v_user, "StandDoneAtUtc" = null, "StandDoneBy" = null
     where "TransactionNo" = p_no;
  end if;
  update public."AdvanceOrderProduction"
     set "AssignedAtUtc" = coalesce("AssignedAtUtc", now()), "AssignedBy" = coalesce("AssignedBy", p_admin_username),
         "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username,
         -- a new maker means work to do again - pull it back out of To Ship
         "ToShipAtUtc" = case when v_user is not null then null else "ToShipAtUtc" end,
         "ToShipBy" = case when v_user is not null then null else "ToShipBy" end
   where "TransactionNo" = p_no
  returning * into v_prod;

  -- Push to just that maker's devices. Never blocks the assignment.
  if v_user is not null then
    begin
      perform public._trigger_web_push(
        case v_role when 'tank' then 'New tank job assigned' else 'New stand job assigned' end,
        'Advance order ' || p_no || coalesce(' - ' || v_customer, ''),
        'online-orders.html',
        array[v_user]);
    exception when others then
      raise notice 'advance order push skipped: %', sqlerrm;
    end;
  end if;

  return public._advance_order_prod_status(v_prod);
end;
$$;

grant execute on function public.staff_assign_advance_order_maker(text, text, text, text, text) to anon;

-- The assigned maker for that part, or a manager. p_done false = undo (manager only - use Send Back
-- to record a reason).
create or replace function public.staff_set_advance_order_part_done(
  p_admin_username text, p_admin_password text, p_no text, p_part text, p_done boolean
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_part text := lower(trim(coalesce(p_part, '')));
  v_prod public."AdvanceOrderProduction";
  v_is_manager boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_part not in ('tank', 'stand') then
    raise exception 'p_part must be ''tank'' or ''stand''.';
  end if;
  select * into v_prod from public."AdvanceOrderProduction" where "TransactionNo" = p_no for update;
  if not found or (case v_part when 'tank' then v_prod."TankMaker" else v_prod."StandMaker" end) is null then
    raise exception 'No % Maker is assigned on advance order %.', initcap(v_part), p_no;
  end if;
  v_is_manager := public._production_is_manager(p_admin_username);
  if not v_is_manager
     and p_admin_username is distinct from (case v_part when 'tank' then v_prod."TankMaker" else v_prod."StandMaker" end) then
    raise exception 'You are not the % Maker on advance order %.', initcap(v_part), p_no;
  end if;
  if not coalesce(p_done, false) and not v_is_manager then
    raise exception 'Only a Production Manager can undo Production Done.';
  end if;
  if v_prod."ShippedAtUtc" is not null then
    raise exception 'Advance order % is already Shipped.', p_no;
  end if;

  if v_part = 'tank' then
    update public."AdvanceOrderProduction"
       set "TankDoneAtUtc" = case when p_done then now() end, "TankDoneBy" = case when p_done then p_admin_username end
     where "TransactionNo" = p_no;
  else
    update public."AdvanceOrderProduction"
       set "StandDoneAtUtc" = case when p_done then now() end, "StandDoneBy" = case when p_done then p_admin_username end
     where "TransactionNo" = p_no;
  end if;
  update public."AdvanceOrderProduction"
     set "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username,
         "ToShipAtUtc" = case when p_done then "ToShipAtUtc" end,
         "ToShipBy" = case when p_done then "ToShipBy" end
   where "TransactionNo" = p_no
  returning * into v_prod;

  if p_done then
    update public."AdvanceOrderRework" set "FixedAtUtc" = now()
     where "TransactionNo" = p_no and "Part" = v_part and "FixedAtUtc" is null;
  end if;

  return public._advance_order_prod_status(v_prod);
end;
$$;

grant execute on function public.staff_set_advance_order_part_done(text, text, text, text, boolean) to anon;

-- Manager: un-does one part with a reason (shows on the maker's card until they mark it done again).
create or replace function public.staff_send_back_advance_order(
  p_admin_username text, p_admin_password text, p_no text, p_part text, p_reason text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_part text := lower(trim(coalesce(p_part, '')));
  v_prod public."AdvanceOrderProduction";
  v_maker text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can send an order back.';
  end if;
  if v_part not in ('tank', 'stand') then
    raise exception 'p_part must be ''tank'' or ''stand''.';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'Give a reason for the rework.';
  end if;
  select * into v_prod from public."AdvanceOrderProduction" where "TransactionNo" = p_no for update;
  v_maker := case v_part when 'tank' then v_prod."TankMaker" else v_prod."StandMaker" end;
  if not found or v_maker is null then
    raise exception 'No % Maker is assigned on advance order %.', initcap(v_part), p_no;
  end if;
  if v_prod."ShippedAtUtc" is not null then
    raise exception 'Advance order % is already Shipped.', p_no;
  end if;
  if (case v_part when 'tank' then v_prod."TankDoneAtUtc" else v_prod."StandDoneAtUtc" end) is null then
    raise exception 'The % part of % is not marked done yet.', v_part, p_no;
  end if;

  insert into public."AdvanceOrderRework" ("TransactionNo", "Part", "Reason", "WasDoneBy", "SentBackBy")
  values (p_no, v_part, trim(p_reason),
          case v_part when 'tank' then v_prod."TankDoneBy" else v_prod."StandDoneBy" end, p_admin_username);

  if v_part = 'tank' then
    update public."AdvanceOrderProduction" set "TankDoneAtUtc" = null, "TankDoneBy" = null where "TransactionNo" = p_no;
  else
    update public."AdvanceOrderProduction" set "StandDoneAtUtc" = null, "StandDoneBy" = null where "TransactionNo" = p_no;
  end if;
  update public."AdvanceOrderProduction"
     set "ToShipAtUtc" = null, "ToShipBy" = null, "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
   where "TransactionNo" = p_no
  returning * into v_prod;

  begin
    perform public._trigger_web_push('Sent back for rework', 'Advance order ' || p_no || ': ' || trim(p_reason),
                                     'online-orders.html', array[v_maker]);
  exception when others then
    raise notice 'advance order push skipped: %', sqlerrm;
  end;

  return public._advance_order_prod_status(v_prod);
end;
$$;

grant execute on function public.staff_send_back_advance_order(text, text, text, text, text) to anon;

-- Manager: p_stage 'To Ship' (production must be done - or no makers assigned), 'Shipped' (must be
-- To Ship), or null to step back (Shipped -> To Ship -> production status).
create or replace function public.staff_set_advance_order_stage(
  p_admin_username text, p_admin_password text, p_no text, p_stage text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_stage text := nullif(trim(coalesce(p_stage, '')), '');
  v_prod public."AdvanceOrderProduction";
  v_status text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can change this.';
  end if;
  if not exists (select 1 from public."AdvanceOrders" where "TransactionNo" = p_no) then
    raise exception 'Advance order % not found.', p_no;
  end if;
  insert into public."AdvanceOrderProduction" ("TransactionNo") values (p_no) on conflict do nothing;
  select * into v_prod from public."AdvanceOrderProduction" where "TransactionNo" = p_no for update;
  v_status := public._advance_order_prod_status(v_prod);

  if v_stage = 'To Ship' then
    if v_status = 'Assigned' then
      raise exception 'Advance order % is still in production - every assigned part must be Production Done first.', p_no;
    end if;
    update public."AdvanceOrderProduction"
       set "ToShipAtUtc" = now(), "ToShipBy" = p_admin_username, "ShippedAtUtc" = null, "ShippedBy" = null
     where "TransactionNo" = p_no;
  elsif v_stage = 'Shipped' then
    if v_status is distinct from 'To Ship' then
      raise exception 'Advance order % must be To Ship before it can be marked Shipped.', p_no;
    end if;
    update public."AdvanceOrderProduction" set "ShippedAtUtc" = now(), "ShippedBy" = p_admin_username where "TransactionNo" = p_no;
  elsif v_stage is null then
    if v_status = 'Shipped' then
      update public."AdvanceOrderProduction" set "ShippedAtUtc" = null, "ShippedBy" = null where "TransactionNo" = p_no;
    else
      update public."AdvanceOrderProduction" set "ToShipAtUtc" = null, "ToShipBy" = null where "TransactionNo" = p_no;
    end if;
  else
    raise exception 'p_stage must be ''To Ship'', ''Shipped'' or null.';
  end if;

  update public."AdvanceOrderProduction" set "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
   where "TransactionNo" = p_no
  returning * into v_prod;
  return public._advance_order_prod_status(v_prod);
end;
$$;

grant execute on function public.staff_set_advance_order_stage(text, text, text, text) to anon;

-- ============================================================================
-- 6. Makers' My Assignments - advance orders where the caller has a part not done yet
-- ============================================================================

create or replace function public.staff_list_my_advance_orders(p_admin_username text, p_admin_password text)
returns table(
  transaction_no text, receipt_no text, customer_name text, order_description text,
  order_date date, warehouse text, my_parts text[], open_rework text[]
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
    select a."TransactionNo"::text, a."ReceiptNo"::text, a."CustomerName"::text, a."Order_Description"::text,
           a."Date", a."Warehouse"::text,
           array_remove(array[
             case when p."TankMaker" = p_admin_username and p."TankDoneAtUtc" is null then 'tank' end,
             case when p."StandMaker" = p_admin_username and p."StandDoneAtUtc" is null then 'stand' end
           ], null),
           array(select r."Reason" from public."AdvanceOrderRework" r
                 where r."TransactionNo" = a."TransactionNo" and r."FixedAtUtc" is null
                   and ((r."Part" = 'tank' and p."TankMaker" = p_admin_username)
                        or (r."Part" = 'stand' and p."StandMaker" = p_admin_username))
                 order by r."SentBackAtUtc")
    from public."AdvanceOrderProduction" p
    join public."AdvanceOrders" a on a."TransactionNo" = p."TransactionNo"
    where p."ShippedAtUtc" is null and p."ToShipAtUtc" is null
      and ((p."TankMaker" = p_admin_username and p."TankDoneAtUtc" is null)
        or (p."StandMaker" = p_admin_username and p."StandDoneAtUtc" is null))
    order by a."Date" nulls last, a."TransactionNo";
end;
$$;

grant execute on function public.staff_list_my_advance_orders(text, text) to anon;

notify pgrst, 'reload schema';

-- Read-only check: advance orders per production stage (all "New" right after the first run).
select coalesce(public._advance_order_prod_status(p), 'New') as stage, count(*) as orders
from public."AdvanceOrders" a
left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
group by 1
order by 1;
