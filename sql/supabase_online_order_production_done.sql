-- Per-person "Production Done" for assigned makers - per "for the user view.. can you give them a
-- button where they can do production done on their side.. be careful because an order can be
-- assigned to multiple user/employee".
--
-- Each assignee marks only THEIR part of the order done: the Tank Maker the tank, the Stand Maker
-- the stand (someone assigned both marks both at once). A custom order with neither an aquarium nor
-- a stand line is the Dispatcher's part (same rule as _online_order_assignment_complete in
-- supabase_online_order_assigned_status.sql). The portal shows the order as "Production Done" once
-- every needed part is done.
--
-- Deliberately does NOT change the order's status or touch Pancake: the POS "Production Done" is a
-- whole-order action (moves it to To Ship / Pending Transfer, messages the customer, claims
-- serials), which stays with the Production Manager / POS once every part is done.
--
-- A done mark only counts while its DoneBy is still that role's assignee, so reassigning a role
-- automatically "un-dones" it for the new person - no change needed to admin_assign_online_order_maker.
--
-- Stored in its own table (not new OnlineOrders columns) so running this never needs a lock on
-- OnlineOrders - see the deadlock note in supabase_online_order_assigned_status.sql.
--
-- Run AFTER supabase_online_order_dispatcher.sql (uses OnlineOrders."AssignedDispatcher").

create table if not exists public."OnlineOrderProductionDone" (
  "OrderID" text not null,
  "Role" text not null check ("Role" in ('tank', 'stand', 'dispatcher')),
  "DoneBy" text not null,
  "DoneAtUtc" timestamptz not null default now(),
  primary key ("OrderID", "Role")
);

alter table public."OnlineOrderProductionDone" enable row level security;
revoke all on public."OnlineOrderProductionDone" from anon, authenticated;

-- Which parts this order needs done: tank / stand for custom aquarium / stand lines; dispatcher
-- for a custom order with neither. Normal (non-custom) orders need none.
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
        where ol."OrderID" = p_order_id
          and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')
      ) as has_custom,
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
      ) as needs_stand
  )
  select case
    when not has_custom then array[]::text[]
    when needs_tank or needs_stand then
      (case when needs_tank then array['tank'] else array[]::text[] end)
      || (case when needs_stand then array['stand'] else array[]::text[] end)
    else array['dispatcher']
  end
  from f;
$$;

-- ---------------------------------------------------------------------------
-- Mark (p_done = true) or undo (false) the caller's own part(s) of an order.
drop function if exists public.staff_set_online_order_production_done(text, text, text, boolean);

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

  if lower(trim(coalesce(v_order."Status", ''))) not in ('confirmed', 'submitted', 'printed', 'assigned') then
    return query select false, format('This order is already %s - production can''t be changed.', v_order."Status")::text, false;
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
-- Done marks for the orders on screen - only marks by the role's CURRENT assignee.
drop function if exists public.staff_get_online_order_production_done(text, text, text[]);

create or replace function public.staff_get_online_order_production_done(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, role text, done_by text, done_by_name text, done_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select d."OrderID", d."Role", d."DoneBy", coalesce(nullif(trim(s."DisplayName"), ''), d."DoneBy")::text, d."DoneAtUtc"
    from public."OnlineOrderProductionDone" d
    join public."OnlineOrders" o on o."OrderID" = d."OrderID"
    left join public."StaffUsers" s on s."Username" = d."DoneBy"
    where d."OrderID" = any(p_order_ids)
      and d."DoneBy" = case d."Role" when 'tank' then o."AssignedTankMaker" when 'stand' then o."AssignedStandMaker" else o."AssignedDispatcher" end;
end;
$$;

grant execute on function public.staff_get_online_order_production_done(text, text, text[]) to anon;

-- Internal helper: not callable from the website directly (see supabase_online_order_mark_shipped.sql).
revoke execute on function public._online_order_production_roles(text) from public, anon, authenticated;
