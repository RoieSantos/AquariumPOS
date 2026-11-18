-- New Staff Role "Sales Manager" - per "i want a sales manager permission.. same as sales user but
-- this sales manager can now remove scheduled order in the calendar. Also once removed i want a
-- log who remove what" (2026-11-18).
--
-- 1. SalesManager added to the allowed Staff Roles (User Setup > Employee > Roles). Ticking it also
--    turns on Sales User, so a Sales Manager gets everything a Sales User has.
-- 2. DeliveryStopRemovals - one row per removed calendar stop: who removed it, when, and a snapshot
--    of the stop (order, customer, date, route, address, notes + the full row as JSON).
-- 3. admin_delete_delivery_stop - Super User OR Sales Manager (was Super User only,
--    supabase_delivery_stop_remove_superuser_only.sql), and writes the log row before deleting.
-- 4. admin_list_delivery_stop_removals - the log, for the "Removed Stops" button on Delivery.
-- 5. admin_set_portal_order_delivery_fee - Sales Manager can also adjust an order's delivery fee.
--
-- Run AFTER supabase_catalog_editor_role.sql (current role list), supabase_staff_session_tokens.sql
-- (_staff_secret_ok) and supabase_pickup_order_delivery_fee_remove.sql. Do NOT re-run
-- supabase_delivery_stop_remove_superuser_only.sql or supabase_pickup_order_delivery_fee_remove.sql
-- after this one (they would drop the Sales Manager access) - if you must, re-run this file after them.
-- Any future file that adds a role must keep 'SalesManager' in the list. Safe to re-run.
-- Needs js/delivery.js ?v=salesmgr1 and js/userSetup.js ?v=10.

-- ---------------------------------------------------------------------------
-- 1. Allowed roles (+ SalesManager)

alter table public."StaffUsers" drop constraint if exists "CK_StaffUsers_StaffRoles";
alter table public."StaffUsers"
  add constraint "CK_StaffUsers_StaffRoles"
  check ("StaffRoles" <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier', 'ProductionManager', 'AllBranchFabrication', 'CatalogEditor', 'SalesManager']::text[]);

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

  if not (v_roles <@ array['StandMaker', 'TankMaker', 'Dispatcher', 'Cashier', 'ProductionManager', 'AllBranchFabrication', 'CatalogEditor', 'SalesManager']::text[]) then
    return query select false, 'Roles must be Stand Maker, Tank Maker, Dispatcher, Cashier, Production Manager, All-Branch Fabrication, Catalog Editor, or Sales Manager.'::text;
    return;
  end if;

  update public."StaffUsers"
  set "StaffRoles" = v_roles,
      -- A Sales Manager is a Sales User plus extra rights.
      "SalesUser" = case when 'SalesManager' = any(v_roles) then true else "SalesUser" end
  where "Username" = p_target_username;

  if not found then
    return query select false, 'That user no longer exists.'::text;
    return;
  end if;

  return query select true, 'Roles updated.'::text;
end;
$$;

grant execute on function public.admin_set_staff_user_roles(text, text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- 2. Super User OR Sales Manager

create or replace function public.is_sales_manager_authorized(p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_super_user boolean;
  v_roles text[];
begin
  select "PasswordHash", "IsActive", "SuperUser", "StaffRoles"
    into v_password_hash, v_is_active, v_super_user, v_roles
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active
     or not (coalesce(v_super_user, false) or 'SalesManager' = any(coalesce(v_roles, '{}'::text[]))) then
    return false;
  end if;

  -- Accepts the portal's 'stok_' session token as well as the password (supabase_staff_session_tokens.sql).
  return public._staff_secret_ok(p_password, v_password_hash);
end;
$$;

-- Not granted to anon - only called from inside the functions below.

-- ---------------------------------------------------------------------------
-- 3. Removal log

create table if not exists public."DeliveryStopRemovals" (
  "RemovalID" bigint generated always as identity primary key,
  "RemovedBy" varchar(100) not null,
  "RemovedAtUtc" timestamptz not null default now(),
  "StopID" uuid not null,
  "OrderID" varchar(100),
  "CustomerName" varchar(255),
  "DeliveryDate" date,
  "RouteName" varchar(200),
  "Address" varchar(1000),
  "Notes" varchar(1000),
  "ScheduledBy" varchar(100),
  "ScheduledAtUtc" timestamptz,
  "StopSnapshot" jsonb
);

create index if not exists "IX_DeliveryStopRemovals_RemovedAt" on public."DeliveryStopRemovals" ("RemovedAtUtc" desc);

-- Read/written only through the security-definer RPCs below.
alter table public."DeliveryStopRemovals" enable row level security;
revoke all on public."DeliveryStopRemovals" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Remove a stop (Super User or Sales Manager) + log it

create or replace function public.admin_delete_delivery_stop(p_admin_username text, p_admin_password text, p_stop_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_stop public."DeliveryStops"%rowtype;
  v_order_id text;
begin
  if not public.is_sales_manager_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a Super User or Sales Manager can remove a scheduled stop.';
  end if;

  select * into v_stop from public."DeliveryStops" where "StopID" = p_stop_id;
  if not found then
    raise exception 'That stop no longer exists - refresh the calendar.';
  end if;

  insert into public."DeliveryStopRemovals" (
    "RemovedBy", "StopID", "OrderID", "CustomerName", "DeliveryDate", "RouteName",
    "Address", "Notes", "ScheduledBy", "ScheduledAtUtc", "StopSnapshot")
  select p_admin_username, v_stop."StopID", v_stop."OrderID",
         coalesce(nullif(trim(v_stop."ManualCustomerName"), ''), o."CustomerName"),
         v_stop."DeliveryDate", v_stop."RouteName",
         coalesce(nullif(trim(v_stop."ManualAddress"), ''), nullif(trim(o."ShippingAddress"), ''), v_stop."GeocodedAddress"),
         v_stop."Notes", v_stop."CreatedBy", v_stop."CreatedAtUtc", to_jsonb(v_stop)
  from (select 1) x
  left join public."OnlineOrders" o on o."OrderID" = v_stop."OrderID";

  delete from public."DeliveryStops" where "StopID" = p_stop_id returning "OrderID" into v_order_id;

  if v_order_id is not null and not exists (select 1 from public."DeliveryStops" where "OrderID" = v_order_id) then
    update public."OnlineOrders" set "ForDelivery" = false where "OrderID" = v_order_id;
  end if;
end;
$$;

grant execute on function public.admin_delete_delivery_stop(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- 5. Read the log (Super User or Sales Manager), newest first

create or replace function public.admin_list_delivery_stop_removals(
  p_admin_username text,
  p_admin_password text,
  p_limit int default 200
)
returns table(
  removed_at timestamptz, removed_by text, order_id text, customer_name text,
  delivery_date date, route_name text, address text, notes text,
  scheduled_by text, scheduled_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_sales_manager_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select r."RemovedAtUtc", r."RemovedBy"::text, r."OrderID"::text, r."CustomerName"::text,
           r."DeliveryDate", r."RouteName"::text, r."Address"::text, r."Notes"::text,
           r."ScheduledBy"::text, r."ScheduledAtUtc"
    from public."DeliveryStopRemovals" r
    order by r."RemovedAtUtc" desc
    limit greatest(1, least(coalesce(p_limit, 200), 1000));
end;
$$;

grant execute on function public.admin_list_delivery_stop_removals(text, text, int) to anon;

-- ---------------------------------------------------------------------------
-- 6. Sales Manager can adjust an order's delivery fee - per "sales manager can also adjust delivery fee".
--    admin_set_portal_order_delivery_fee (Online Orders card Delivery Fee, and the order sync from the
--    Delivery calendar's Edit Details) was Super User / Conversations Access only. Patched in place on its
--    LIVE definition (latest: supabase_pickup_order_delivery_fee_remove.sql) so nothing else in it
--    changes. The stop's own fee in Edit Details was already open to all staff. Advance-order fees were
--    already open to Sales Users (supabase_advance_order_fee_sales_user.sql), which a Sales Manager is.

do $$
declare
  c_old constant text := 'not public.is_conversations_authorized(p_admin_username, p_admin_password)';
  c_new constant text := 'not (public.is_conversations_authorized(p_admin_username, p_admin_password) or public.is_sales_manager_authorized(p_admin_username, p_admin_password))';
  v_def text;
begin
  if to_regprocedure('public.admin_set_portal_order_delivery_fee(text, text, text, numeric)') is null then
    raise exception 'admin_set_portal_order_delivery_fee does not exist - run supabase_pickup_order_delivery_fee_remove.sql first.';
  end if;
  v_def := pg_get_functiondef('public.admin_set_portal_order_delivery_fee(text, text, text, numeric)'::regprocedure);
  if position('is_sales_manager_authorized' in v_def) > 0 then
    return; -- already patched by an earlier run
  end if;
  if position(c_old in v_def) = 0 then
    raise exception 'admin_set_portal_order_delivery_fee has no "%" check to widen - not patched. Tell Claude.', c_old;
  end if;
  execute replace(v_def, c_old, c_new);
end;
$$;

-- Verification - one result.
select 'roles allow SalesManager' as check_name,
       (pg_get_constraintdef((select oid from pg_constraint where conname = 'CK_StaffUsers_StaffRoles')) like '%SalesManager%')::text as ok
union all
select 'remove stop: Super User or Sales Manager + logs',
       (pg_get_functiondef('public.admin_delete_delivery_stop(text, text, uuid)'::regprocedure) like '%is_sales_manager_authorized%'
        and pg_get_functiondef('public.admin_delete_delivery_stop(text, text, uuid)'::regprocedure) like '%DeliveryStopRemovals%')::text
union all
select 'removal log table', (to_regclass('public."DeliveryStopRemovals"') is not null)::text
union all
select 'order delivery fee: Sales Manager allowed',
       (pg_get_functiondef('public.admin_set_portal_order_delivery_fee(text, text, text, numeric)'::regprocedure) like '%is_sales_manager_authorized%')::text;
