-- Lets staff assign an online order to a "Production Member" (see
-- supabase_staff_users_production_member_field.sql) - the team member building a custom item
-- (custom aquarium/stand/sump/etc) on that order. Purely local bookkeeping, no Pancake call - the
-- assignment only exists in the portal, unlike Status which mirrors what Pancake itself has.
--
-- Run this AFTER supabase_staff_users_production_member_field.sql (needs the "ProductionMember"
-- column to validate against) and supabase_orders_sync_tables.sql (needs "OnlineOrders").

alter table public."OnlineOrders"
    add column if not exists "AssignedProductionMember" text;

-- ---------------------------------------------------------------------------
-- staff_list_production_members: populates the Online Orders "Assigned To" dropdown. Any active
-- staff can call this (is_staff_authorized, not is_admin_authorized) - same convention as
-- staff_search_vendors (supabase_vendor_tables.sql), which any active staff also needs for a
-- lightweight picker outside the admin-only Setup pages. No search/limit param - the Production
-- Member roster is always small.

drop function if exists public.staff_list_production_members(text, text);

create or replace function public.staff_list_production_members(p_admin_username text, p_admin_password text)
returns table(username text, display_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "Username"::text, coalesce(nullif(trim("DisplayName"), ''), "Username")::text
    from public."StaffUsers"
    where "IsActive" and "ProductionMember"
    order by coalesce(nullif(trim("DisplayName"), ''), "Username");
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_assign_online_order_production_member: sets or clears (p_username = null/blank) the
-- order's assigned production member. Re-validates p_username is still an active Production
-- Member server-side too, not just filtered client-side by staff_list_production_members' list -
-- this function is reachable directly by anyone with valid staff credentials.

drop function if exists public.admin_assign_online_order_production_member(text, text, text, text);

create or replace function public.admin_assign_online_order_production_member(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_username text default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_username text := nullif(trim(coalesce(p_username, '')), '');
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if not exists (select 1 from public."OnlineOrders" where "OrderID" = p_order_id) then
    return query select false, 'Order not found.'::text;
    return;
  end if;

  if v_username is not null and not exists (
    select 1 from public."StaffUsers" where "Username" = v_username and "IsActive" and "ProductionMember"
  ) then
    return query select false, 'That user is not an active Production Member.'::text;
    return;
  end if;

  update public."OnlineOrders" set "AssignedProductionMember" = v_username where "OrderID" = p_order_id;

  return query select true, 'Assignment updated.'::text;
end;
$$;

grant execute on function public.staff_list_production_members(text, text) to anon;
grant execute on function public.admin_assign_online_order_production_member(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Per follow-up: "maybe each order can be assign a tank maker and a stand maker. if an order has
-- Aquarium order assign tank maker, if stand then we can assign stand maker" - a single order can
-- have a custom aquarium line, a custom stand line, or both, and per direct earlier answer these
-- are built by different people, so one generic "Assigned To" isn't enough. Splits the single
-- AssignedProductionMember above into two role-specific slots instead. AssignedProductionMember
-- itself is left in place (not dropped) - purely to avoid discarding any assignment staff may
-- already have entered with it; the portal no longer reads/writes it once this file is run.
alter table public."OnlineOrders"
    add column if not exists "AssignedTankMaker" text;
alter table public."OnlineOrders"
    add column if not exists "AssignedStandMaker" text;

-- admin_assign_online_order_maker: like admin_assign_online_order_production_member above, but
-- p_role picks which of the two slots gets set/cleared - avoids two near-duplicate functions for
-- what's otherwise identical validation/update logic. p_role is validated against a fixed list
-- (not just trusted) since, same as p_username, this function is reachable directly by anyone
-- with valid staff credentials, not only through whichever dropdown the portal shows.
drop function if exists public.admin_assign_online_order_maker(text, text, text, text, text);

create or replace function public.admin_assign_online_order_maker(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_role text,
  p_username text default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_username text := nullif(trim(coalesce(p_username, '')), '');
  v_role text := lower(trim(coalesce(p_role, '')));
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if v_role not in ('tank', 'stand') then
    return query select false, 'p_role must be ''tank'' or ''stand''.'::text;
    return;
  end if;

  if not exists (select 1 from public."OnlineOrders" where "OrderID" = p_order_id) then
    return query select false, 'Order not found.'::text;
    return;
  end if;

  if v_username is not null and not exists (
    select 1 from public."StaffUsers" where "Username" = v_username and "IsActive" and "ProductionMember"
  ) then
    return query select false, 'That user is not an active Production Member.'::text;
    return;
  end if;

  if v_role = 'tank' then
    update public."OnlineOrders" set "AssignedTankMaker" = v_username where "OrderID" = p_order_id;
  else
    update public."OnlineOrders" set "AssignedStandMaker" = v_username where "OrderID" = p_order_id;
  end if;

  return query select true, 'Assignment updated.'::text;
end;
$$;

grant execute on function public.admin_assign_online_order_maker(text, text, text, text, text) to anon;
