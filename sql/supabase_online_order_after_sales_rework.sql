-- After-sales rework: Send Back works on Shipped / Delivered / Received orders too - per "its production
-- rework so i need to reassign this to a maker again because there is a fault".
--
-- Before: Send Back (and the maker's Production Done) only worked while the order was still in
-- production (Confirmed / Submitted / Printed / Assigned, or an open walk-in stage). A fault found after
-- delivery couldn't go back to the maker.
--
-- Now, for a Shipped / Delivered / Received order (incl. a picked-up walk-in) - never Cancelled:
--   1. Send Back (Production Manager / Super User) - pick the part(s) + reason, same dialog. Works even
--      if the part was never marked done (older orders); the part needs a maker assigned. Logged in
--      the same OnlineOrderProductionRework table, so the rework count / Rework History include it.
--   2. While that rework is open, the order is back on that maker's My Assignments (and the Super User
--      Maker Assignments page) with the Rework badge + reason. Status stays Delivered (or Shipped...);
--      Pancake, sales and the delivery record are not touched. Changing the maker first is fine - the
--      rework follows the part, not the person.
--   3. The maker's Production Done closes the rework (same rule as before: a done mark newer than the
--      send-back) and the order leaves their list again. Undo isn't offered on these.
--
-- Changes:
--   _online_order_rework_reopened(order, role)     - new helper: closed order + open rework on that part.
--   _online_order_my_rework_reopened(order, user)  - new helper: same, on a part this user is assigned.
--   admin_send_back_online_order_production         - full replace (only ever defined in
--       supabase_online_order_production_rework.sql and supabase_walkin_order_portal_status.sql).
--   staff_set_online_order_production_done          - full replace (only ever defined in
--       supabase_online_order_production_done.sql and supabase_walkin_order_portal_status.sql).
--   admin_list_online_orders (My Assignments)       - LIVE definition patched in one spot (the list
--       has many versions - nothing newer is overwritten), every overload.
--   admin_list_maker_assignments                    - LIVE definition patched in one spot (inline
--       lookup, not the helper, since it scans every closed order).
--
-- Run AFTER supabase_walkin_order_portal_status.sql and supabase_maker_assignments_view.sql. If
-- either of those, or any file that redefines admin_list_online_orders, is re-run later, run this
-- again after. Safe to re-run. Needs js/onlineOrders.js ?v=aftersales1.
-- Ends with ONE check result: every 'function' row should say ok; 'already reopened' rows are
-- Shipped / Delivered orders that already have an open rework and will show on a maker's list now.

-- ---------------------------------------------------------------------------
-- 1. Helpers.
create or replace function public._online_order_rework_reopened(p_order_id text, p_role text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public."OnlineOrders" o
    join public."OnlineOrderProductionRework" w on w."OrderID" = o."OrderID" and w."Role" = p_role
    where o."OrderID" = p_order_id
      and lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2', 'received', '3')
      and not exists (
        select 1 from public."OnlineOrderProductionDone" d
        where d."OrderID" = w."OrderID" and d."Role" = w."Role" and d."DoneAtUtc" > w."SentBackAtUtc"
      )
  );
$$;
revoke execute on function public._online_order_rework_reopened(text, text) from public, anon, authenticated;

create or replace function public._online_order_my_rework_reopened(p_order_id text, p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public."OnlineOrders" o
    where o."OrderID" = p_order_id
      and ((o."AssignedTankMaker" = p_username and public._online_order_rework_reopened(p_order_id, 'tank'))
        or (o."AssignedStandMaker" = p_username and public._online_order_rework_reopened(p_order_id, 'stand')))
  );
$$;
revoke execute on function public._online_order_my_rework_reopened(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Send Back - same as supabase_walkin_order_portal_status.sql, plus the after-sales branch.
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
  v_order public."OnlineOrders"%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_count int;
  v_roles text[];
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

  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    return query select false, 'Order not found.'::text;
    return;
  end if;

  -- In production (incl. open walk-in stages): as before - only parts marked done can go back.
  if public._online_order_production_open(p_order_id) then
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
    return;
  end if;

  -- After-sales rework (this file): Shipped / Delivered / Received - never Cancelled.
  if lower(trim(coalesce(v_order."Status", ''))) not in ('shipped', 'delivered', '2', 'received', '3') then
    return query select false, format('This order is already %s - it can''t be sent back from here.',
      coalesce(public._walkin_order_stage(p_order_id), v_order."Status"))::text;
    return;
  end if;

  -- Parts this order needs that have a maker assigned (a done mark isn't required - older orders
  -- may never have had one).
  select array_agg(r) into v_roles
  from unnest(p_roles) as r
  where r in ('tank', 'stand')
    and r = any(public._online_order_production_roles(p_order_id))
    and nullif(trim(coalesce(case r when 'tank' then v_order."AssignedTankMaker" else v_order."AssignedStandMaker" end, '')), '') is not null;

  if v_roles is null then
    return query select false, 'Assign a maker to that part first - then send it back.'::text;
    return;
  end if;

  with removed as (
    delete from public."OnlineOrderProductionDone"
    where "OrderID" = p_order_id and "Role" = any(v_roles)
    returning "Role", "DoneBy", "DoneAtUtc"
  ), logged as (
    insert into public."OnlineOrderProductionRework" ("OrderID", "Role", "Reason", "SentBackBy", "PrevDoneBy", "PrevDoneAtUtc")
    -- Tagged to whoever made it: the done mark's maker, else (never marked done) the maker assigned
    -- right now - so Send Back BEFORE changing the maker on such an order.
    select p_order_id, r, v_reason, p_admin_username,
           coalesce(rm."DoneBy", case r when 'tank' then v_order."AssignedTankMaker" else v_order."AssignedStandMaker" end),
           rm."DoneAtUtc"
    from unnest(v_roles) as r
    left join removed rm on rm."Role" = r
    returning 1
  )
  select count(*) into v_count from logged;

  return query select true, format('Sent back %s part(s) for rework. The order stays %s - it''s back on the maker''s list until they mark it done.',
    v_count, v_order."Status")::text;
end;
$$;
grant execute on function public.admin_send_back_online_order_production(text, text, text, text[], text) to anon;

-- ---------------------------------------------------------------------------
-- 3. Production Done - same as supabase_walkin_order_portal_status.sql, plus: a closed order with an
-- open rework on the caller's part can be marked done (that part only). No undo there.
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
  v_reopened boolean := false;
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

  -- WALK-IN: open walk-in stages count too. AFTER-SALES REWORK (this file): a closed order with an
  -- open rework on this user's part.
  if not public._online_order_production_open(p_order_id) then
    v_reopened := public._online_order_my_rework_reopened(p_order_id, p_admin_username);
    if not v_reopened or not p_done then
      return query select false, format('This order is already %s - production can''t be changed.',
        coalesce(public._walkin_order_stage(p_order_id), v_order."Status"))::text, false;
      return;
    end if;
  end if;

  v_needed := public._online_order_production_roles(p_order_id);
  if 'tank' = any(v_needed) and v_order."AssignedTankMaker" = p_admin_username then v_mine := array_append(v_mine, 'tank'); end if;
  if 'stand' = any(v_needed) and v_order."AssignedStandMaker" = p_admin_username then v_mine := array_append(v_mine, 'stand'); end if;
  if 'dispatcher' = any(v_needed) and v_order."AssignedDispatcher" = p_admin_username then v_mine := array_append(v_mine, 'dispatcher'); end if;

  -- After-sales: only the part(s) sent back.
  if v_reopened then
    v_mine := array(select r from unnest(v_mine) as r where public._online_order_rework_reopened(p_order_id, r));
  end if;

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

  return query select true,
    (case when v_reopened then 'Rework marked done.' when p_done then 'Marked as done.' else 'Production done undone.' end)::text,
    coalesce(v_all_done, false);
end;
$$;
grant execute on function public.staff_set_online_order_production_done(text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- 4. My Assignments (admin_list_online_orders, every overload) + Maker Assignments page: patch the
-- LIVE definitions in one spot each, so nothing newer in them is overwritten.
do $$
declare
  r record;
  v_def text;
  v_new text;
begin
  -- My Assignments: one more branch in the p_assigned_to_me CASE, right before its "else false".
  for r in
    select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_list_online_orders'
  loop
    v_def := pg_get_functiondef(r.oid);
    if v_def ilike '%after-sales rework%' then
      raise notice 'admin_list_online_orders (oid %) already has after-sales rework - left as is.', r.oid;
      continue;
    end if;
    -- Inline (no helper call per row) - the helper version timed out on makers' lists
    -- (supabase_online_order_after_sales_rework_speed_fix.sql).
    v_new := regexp_replace(
      v_def,
      '(and\s+lower\(trim\(coalesce\(o\."Status",\s*''''\)\)\)\s+in\s+\(''to ship'',\s*''packing'',\s*''packed''\)\)\s*\)\s*)else\s+false',
      E'\\1-- After-sales rework (supabase_online_order_after_sales_rework.sql): a Shipped / Delivered order\n'
        || E'            -- is back on its maker''s list while a part of theirs is sent back and not re-done.\n'
        || E'            when p_admin_username in (o."AssignedTankMaker", o."AssignedStandMaker")\n'
        || E'              and lower(trim(coalesce(o."Status", \'\'))) in (\'shipped\', \'delivered\', \'2\', \'received\', \'3\')\n'
        || E'              and exists (select 1 from public."OnlineOrderProductionRework" ar\n'
        || E'                          where ar."OrderID" = o."OrderID"\n'
        || E'                            and ((ar."Role" = \'tank\' and o."AssignedTankMaker" = p_admin_username)\n'
        || E'                              or (ar."Role" = \'stand\' and o."AssignedStandMaker" = p_admin_username))\n'
        || E'                            and not exists (select 1 from public."OnlineOrderProductionDone" ad\n'
        || E'                                            where ad."OrderID" = ar."OrderID" and ad."Role" = ar."Role"\n'
        || E'                                              and ad."DoneAtUtc" > ar."SentBackAtUtc")) then true\n'
        || '            else false',
      'i');
    if v_new <> v_def then
      execute v_new;
      raise notice 'Added after-sales rework to admin_list_online_orders (oid %).', r.oid;
    else
      raise warning 'Could not find the My Assignments CASE in admin_list_online_orders (oid %) - NOT changed.', r.oid;
    end if;
  end loop;

  -- Maker Assignments page: the online branch's open-status filter.
  for r in
    select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_list_maker_assignments'
  loop
    v_def := pg_get_functiondef(r.oid);
    if v_def ilike '%after-sales rework%' then
      raise notice 'admin_list_maker_assignments (oid %) already has after-sales rework - left as is.', r.oid;
      continue;
    end if;
    -- First match only - the Online / Walk-in branch.
    v_new := regexp_replace(
      v_def,
      'and\s+(lower\(trim\(coalesce\(o\."Status",\s*''''\)\)\)\s+not\s+in\s+\(''shipped'',\s*''delivered'',\s*''2'',\s*''received'',\s*''3'',\s*''canceled'',\s*''cancelled''\))',
      -- Inline (not the helper) so the planner can join it - this runs over every closed order.
      E'and (\\1\n'
        || E'             -- after-sales rework (supabase_online_order_after_sales_rework.sql)\n'
        || E'             or (lower(trim(coalesce(o."Status", \'\'))) not in (\'canceled\', \'cancelled\')\n'
        || E'                 and exists (select 1 from public."OnlineOrderProductionRework" ar\n'
        || E'                             where ar."OrderID" = o."OrderID" and ar."Role" = m.part\n'
        || E'                               and not exists (select 1 from public."OnlineOrderProductionDone" ad\n'
        || E'                                               where ad."OrderID" = ar."OrderID" and ad."Role" = ar."Role"\n'
        || E'                                                 and ad."DoneAtUtc" > ar."SentBackAtUtc"))))',
      'i');
    if v_new <> v_def then
      execute v_new;
      raise notice 'Added after-sales rework to admin_list_maker_assignments (oid %).', r.oid;
    else
      raise warning 'Could not find the status filter in admin_list_maker_assignments (oid %) - NOT changed.', r.oid;
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';

-- Check (one result): every 'function' row ok = true; 'already reopened' rows = closed orders that
-- already had an open rework, which now show on that maker's list.
select 'function'::text as section, p.proname::text as name,
       case p.proname
         when 'admin_list_online_orders' then p.prosrc ilike '%after-sales rework%'
         when 'admin_list_maker_assignments' then p.prosrc ilike '%after-sales rework%'
         when 'admin_send_back_online_order_production' then p.prosrc ilike '%After-sales rework%'
         when 'staff_set_online_order_production_done' then p.prosrc ilike '%v_reopened%'
         else true
       end as ok,
       pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_list_online_orders', 'admin_list_maker_assignments', 'admin_send_back_online_order_production',
                    'staff_set_online_order_production_done', '_online_order_rework_reopened', '_online_order_my_rework_reopened')
union all
select 'already reopened', o."OrderID"::text, null,
       o."Status" || ' - ' || string_agg(distinct w."Role", ' + ')
from public."OnlineOrders" o
join public."OnlineOrderProductionRework" w on w."OrderID" = o."OrderID"
where public._online_order_rework_reopened(o."OrderID", w."Role")
group by o."OrderID", o."Status"
order by 1 desc, 2;
