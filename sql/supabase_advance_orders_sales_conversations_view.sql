-- Advance Orders tab for Sales Users and Conversations Access staff too (per "can you give access to
-- sales user and conversation access permission"). Same view-only, own-branch access as a Store Manager
-- (supabase_advance_orders_store_manager_view.sql): list, stage counts, open an order's lines / rework
-- history, only for orders whose "Warehouse" matches their StaffUsers."WarehouseName" (no branch set =
-- nothing shown). Assigning makers and moving stages stays Super User / Production Manager only.
--
-- Only widens _advance_order_is_viewer - admin_list_advance_orders, staff_get_advance_order_status_summary
-- and _advance_order_can_view all go through it, and _advance_order_viewer_branch already limits every
-- non-manager viewer to their own branch.
--
-- Run AFTER supabase_advance_orders_store_manager_view.sql. Safe to re-run. (That file now carries the
-- same widened check, so re-running it later won't take this access away.)

-- Production Manager, or an active Store Manager / Sales User / Conversations Access account - may view
-- (not manage) advance orders.
create or replace function public._advance_order_is_viewer(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public._production_is_manager(p_username)
      or exists (select 1 from public."StaffUsers"
                 where "Username" = p_username and "IsActive"
                   and (coalesce("StoreManager", false)
                        or coalesce("SalesUser", false)
                        or coalesce("ConversationsStaff", false)));
$$;

revoke execute on function public._advance_order_is_viewer(text) from public, anon, authenticated;
