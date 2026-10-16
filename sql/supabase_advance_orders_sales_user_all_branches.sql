-- Advance Orders: a Sales User with no warehouse ("All Warehouses") sees every branch - per "the sales
-- user should still see the advance order even though their warehouse is (All Warehouse) give them access
-- please".
--
-- Before: viewers (Store Manager / Sales User / Conversations Access) only saw advance orders whose
-- "Warehouse" matched their StaffUsers."WarehouseName"; a blank WarehouseName matched nothing, so the
-- Advance Orders tab was empty for them.
--
-- Now _advance_order_viewer_branch returns null (= every branch, same as Super User / Production Manager)
-- for an active Sales User whose WarehouseName is blank. A Sales User WITH a warehouse still sees only that
-- branch. Store Managers and Conversations Access staff with a blank warehouse are unchanged (still none).
-- Still view-only - assigning makers / moving stages stays Super User / Production Manager.
--
-- admin_list_advance_orders, staff_get_advance_order_status_summary, the To Follow and custom-flag lists
-- already treat a null branch as "all". _advance_order_can_view (open an order's lines / rework) compared
-- with "=", which never matches null - re-created here to accept it too.
--
-- Run AFTER supabase_advance_orders_store_manager_view.sql. If that file (or
-- supabase_advance_order_production.sql) is ever re-run, run this file again afterwards.
-- Safe to re-run. Replaces two functions - no table changes.

create or replace function public._advance_order_viewer_branch(p_username text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when public._production_is_manager(p_username)
      or exists (select 1 from public."StaffUsers" where "Username" = p_username and "IsActive" and "SuperUser")
      then null
    -- (this file) Sales User set to All Warehouses: every branch.
    when exists (select 1 from public."StaffUsers"
                 where "Username" = p_username and "IsActive" and coalesce("SalesUser", false)
                   and nullif(trim(coalesce("WarehouseName", '')), '') is null)
      then null
    else coalesce((select lower(trim(coalesce("WarehouseName", ''))) from public."StaffUsers"
                   where "Username" = p_username limit 1), '')
  end;
$$;

revoke execute on function public._advance_order_viewer_branch(text) from public, anon, authenticated;

create or replace function public._advance_order_can_view(p_username text, p_no text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._production_is_manager(p_username)
      or (public._advance_order_is_viewer(p_username)
          and exists (select 1 from public."AdvanceOrders" a
                      where a."TransactionNo" = p_no
                        -- (this file) null branch = every branch (Sales User on All Warehouses).
                        and (public._advance_order_viewer_branch(p_username) is null
                             or lower(trim(coalesce(a."Warehouse", ''))) = public._advance_order_viewer_branch(p_username))))
      or exists (select 1 from public."StaffUsers" where "Username" = p_username and "IsActive" and "SuperUser")
      or exists (select 1 from public."AdvanceOrderProduction" p
                 where p."TransactionNo" = p_no and p_username in (p."TankMaker", p."StandMaker"));
$$;

revoke execute on function public._advance_order_can_view(text, text) from public, anon, authenticated;
