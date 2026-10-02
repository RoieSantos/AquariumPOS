-- Stock build -> Assigned. Per "for stocks orders from online order we can tag the maker into the online
-- order so we can get better tracking" / "how can the user know that this order is assigned to maker and
-- currently doing production order? ... the order is still floating on confirmed or printed" / "yes they
-- will also receive a messaged too since its assigned".
--
-- Before: Assign - build missing units (Online Orders, supabase_online_order_stock_ship.sql) made a
-- Production Order with the makers on it and linked it to the online order, but the online order itself
-- kept no maker and stayed Confirmed / Printed. Now a stock order (no custom tank/stand roles) with a
-- linked Production Order:
--   1. Gets the Production Order's Tank / Stand Maker copied onto it (trigger below - on link and on any
--      later maker change), so the order list / filters show who is building it.
--   2. Counts as fully assigned (_online_order_assignment_complete), so admin_sync_online_order_assigned_
--      status moves it to Assigned (portal + Pancake 11) and sends the first-Assigned "in production"
--      customer message, same as a custom order. The page calls it right after creating the build.
--   3. Stays off the maker's My Assignments online-order list (_online_order_my_parts_done) - the job is
--      already there as its Production Order card, where they mark it done. No duplicate card.
--   4. Sends only one push: "Production order released to you". The online-order "New tank/stand job
--      assigned" push is skipped for these orders.
--   5. If its Production Order is deleted / unlinked and no other one is left, the copied makers are
--      cleared and an Assigned order goes back to its previous status (portal + Pancake). If Pancake
--      can't be reached then, it simply stays Assigned on both sides - the delete still goes through.
--
-- Run AFTER supabase_online_order_stock_ship.sql, supabase_web_push_targeted.sql,
-- supabase_online_order_dispatcher_on_ship.sql and supabase_online_order_my_assignments_hide_done.sql.
-- Functions + one trigger, plus a one-time copy of makers for builds that are already linked. Safe to
-- re-run.

-- ---------------------------------------------------------------------------
-- A stock order (no custom tank/stand roles) with at least one Production Order built for it.
create or replace function public._online_order_has_stock_build(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public."ProductionOrders" po where po."SourceOnlineOrderId" = p_order_id)
     and cardinality(public._online_order_production_roles(p_order_id)) = 0;
$$;

revoke execute on function public._online_order_has_stock_build(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Same as supabase_online_order_dispatcher_on_ship.sql, plus: a stock build counts as assigned.
create or replace function public._online_order_assignment_complete(p_order_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select cardinality(r.roles) > 0
      and (not 'tank' = any(r.roles) or nullif(trim(coalesce(o."AssignedTankMaker", '')), '') is not null)
      and (not 'stand' = any(r.roles) or nullif(trim(coalesce(o."AssignedStandMaker", '')), '') is not null)
    from public."OnlineOrders" o
    cross join lateral (select public._online_order_production_roles(p_order_id) as roles) r
    where o."OrderID" = p_order_id
  ), false)
  or public._online_order_has_stock_build(p_order_id);
$$;

revoke execute on function public._online_order_assignment_complete(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Same as supabase_online_order_my_assignments_hide_done.sql, plus: a stock build counts as "done" for
-- the online-order list, so it leaves My Assignments there (it's on the Production Order card instead).
create or replace function public._online_order_my_parts_done(p_order_id text, p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._online_order_has_stock_build(p_order_id) or coalesce((
    select count(*) > 0 and bool_and(exists (
      select 1 from public."OnlineOrderProductionDone" d
      where d."OrderID" = p_order_id and d."Role" = r.part and d."DoneBy" = p_username
    ))
    from public."OnlineOrders" o
    cross join unnest(public._online_order_production_roles(p_order_id)) as r(part)
    where o."OrderID" = p_order_id
      and p_username = case r.part when 'tank' then o."AssignedTankMaker" when 'stand' then o."AssignedStandMaker" else o."AssignedDispatcher" end
  ), false);
$$;

revoke execute on function public._online_order_my_parts_done(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Same as supabase_web_push_targeted.sql, plus: no push for a stock build - the maker gets
-- "Production order released to you" for it instead.
create or replace function public._notify_online_order_maker_assigned()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order text := 'Order ' || coalesce(NEW."OrderID", '-') || ' - ' || coalesce(NEW."CustomerName", '-');
begin
  if public._online_order_has_stock_build(NEW."OrderID") then
    return NEW;
  end if;

  if NEW."AssignedTankMaker" is not null and NEW."AssignedTankMaker" is distinct from OLD."AssignedTankMaker" then
    perform public._trigger_web_push('New tank job assigned', v_order, 'online-orders.html', array[NEW."AssignedTankMaker"::text]);
  end if;

  if NEW."AssignedStandMaker" is not null and NEW."AssignedStandMaker" is distinct from OLD."AssignedStandMaker" then
    perform public._trigger_web_push('New stand job assigned', v_order, 'online-orders.html', array[NEW."AssignedStandMaker"::text]);
  end if;

  return NEW;
end;
$$;

-- ---------------------------------------------------------------------------
-- An online order lost its (last) Production Order: clear the makers that came from it and, if it was
-- Assigned, put it back to its previous status in the portal and Pancake. Never raises.
create or replace function public._online_order_undo_stock_build(p_order_id text, p_tank_maker text, p_stand_maker text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_pre_status text;
  v_target text;
begin
  if p_order_id is null
     or exists (select 1 from public."ProductionOrders" po where po."SourceOnlineOrderId" = p_order_id)
     or cardinality(public._online_order_production_roles(p_order_id)) > 0 then
    return;
  end if;

  update public."OnlineOrders"
  set "AssignedTankMaker" = case when "AssignedTankMaker" = p_tank_maker then null else "AssignedTankMaker" end,
      "AssignedStandMaker" = case when "AssignedStandMaker" = p_stand_maker then null else "AssignedStandMaker" end
  where "OrderID" = p_order_id
    and ("AssignedTankMaker" = p_tank_maker or "AssignedStandMaker" = p_stand_maker);

  select "Status", "PreAssignStatus" into v_status, v_pre_status
  from public."OnlineOrders" where "OrderID" = p_order_id;

  if lower(trim(coalesce(v_status, ''))) = 'assigned' then
    v_target := coalesce(nullif(trim(v_pre_status), ''), 'Confirmed');
    begin
      -- Same Pancake codes as admin_sync_online_order_assigned_status's un-assign branch.
      perform public._pancake_patch_online_order_status(p_order_id,
        jsonb_build_object('status', case lower(v_target) when 'printed' then '13' else 'submitted' end));
      update public."OnlineOrders" set "Status" = v_target, "PreAssignStatus" = null where "OrderID" = p_order_id;
    exception when others then
      -- Pancake unreachable: leave it Assigned in both places rather than block the delete.
      null;
    end;
  end if;
end;
$$;

revoke execute on function public._online_order_undo_stock_build(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Keeps the online order's makers in step with the Production Order built for it.
create or replace function public._sync_online_order_makers_from_production()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_old_order text;
  v_new_order text;
begin
  if TG_OP in ('UPDATE', 'DELETE') then v_old_order := nullif(trim(coalesce(OLD."SourceOnlineOrderId", '')), ''); end if;
  if TG_OP in ('INSERT', 'UPDATE') then v_new_order := nullif(trim(coalesce(NEW."SourceOnlineOrderId", '')), ''); end if;

  -- Linked, or its makers changed: copy them onto the online order (stock orders only - a custom
  -- order's makers are picked in its own Assign popup).
  if v_new_order is not null
     and cardinality(public._online_order_production_roles(v_new_order)) = 0
     and (NEW."TankMaker" is not null or NEW."StandMaker" is not null) then
    update public."OnlineOrders"
    set "AssignedTankMaker" = coalesce(NEW."TankMaker", "AssignedTankMaker"),
        "AssignedStandMaker" = coalesce(NEW."StandMaker", "AssignedStandMaker")
    where "OrderID" = v_new_order
      and ("AssignedTankMaker" is distinct from coalesce(NEW."TankMaker", "AssignedTankMaker")
        or "AssignedStandMaker" is distinct from coalesce(NEW."StandMaker", "AssignedStandMaker"));
  end if;

  -- Deleted, or moved to another order: undo on the order it left (if nothing else builds for it).
  if v_old_order is not null and v_old_order is distinct from v_new_order then
    perform public._online_order_undo_stock_build(v_old_order, OLD."TankMaker", OLD."StandMaker");
  end if;

  return null;
end;
$$;

drop trigger if exists trg_sync_online_order_makers_from_production on public."ProductionOrders";
create trigger trg_sync_online_order_makers_from_production
  after insert or update of "TankMaker", "StandMaker", "SourceOnlineOrderId" or delete on public."ProductionOrders"
  for each row
  execute function public._sync_online_order_makers_from_production();

-- ---------------------------------------------------------------------------
-- One-time: copy makers onto stock orders whose build was linked before this file. (No push - these
-- orders already count as stock builds.) Their status is left alone; the order's next-step button
-- shows "Set Assigned" for them so a Production Manager can move them (and message the customer).
update public."OnlineOrders" o
set "AssignedTankMaker" = coalesce(po."TankMaker", o."AssignedTankMaker"),
    "AssignedStandMaker" = coalesce(po."StandMaker", o."AssignedStandMaker")
from (
  select distinct on (p."SourceOnlineOrderId") p."SourceOnlineOrderId", p."TankMaker", p."StandMaker"
  from public."ProductionOrders" p
  where p."SourceOnlineOrderId" is not null
  order by p."SourceOnlineOrderId", (p."Status" <> 'Finished') desc, p."CreatedAtUtc" desc
) po
where o."OrderID" = po."SourceOnlineOrderId"
  and cardinality(public._online_order_production_roles(o."OrderID")) = 0
  and lower(trim(coalesce(o."Status", ''))) not in ('shipped', 'delivered', '2', 'received', '3', 'canceled', 'cancelled')
  and (o."AssignedTankMaker" is distinct from coalesce(po."TankMaker", o."AssignedTankMaker")
    or o."AssignedStandMaker" is distinct from coalesce(po."StandMaker", o."AssignedStandMaker"));
