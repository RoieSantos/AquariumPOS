-- FIX: Online Orders list error "Could not choose the best candidate function between:
-- public.admin_list_online_orders(...13 args...) and public.admin_list_online_orders(...16 args...)".
--
-- Cause: supabase_online_order_all_branch_fabrication.sql was re-run. It re-created its old 13-arg
-- admin_list_online_orders next to the live 16-arg one (supabase_online_orders_confirmed_date.sql), so
-- PostgREST can't pick, and it overwrote admin_get_online_order_status_summary with a version that has
-- no "Delivered" count.
--
-- This file:
--   1. Drops the stale 13-arg admin_list_online_orders. The live 16-arg one is untouched.
--   2. Re-creates admin_get_online_order_status_summary exactly as in supabase_delivery_stop_done_post.sql
--      (section 5, the newest version - with the Delivered count).
--
-- Don't re-run supabase_online_order_all_branch_fabrication.sql again (it would undo this AND the
-- _online_order_open_fabrication change in supabase_online_order_production_request.sql). Safe to re-run.

-- 1. -------------------------------------------------------------------------
drop function if exists public.admin_list_online_orders(text, text, text, text, text, text, boolean, int, int, text, text[], boolean, boolean);

-- 2. -------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 5. Online Orders status pills: a "Delivered" count of its own (was counted under Shipped).
create or replace function public.admin_get_online_order_status_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null, p_walkin_only boolean default false,
  p_branch_scoped boolean default false)
returns table(status_label text, order_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_all_branch_fab boolean := false;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if coalesce(p_branch_scoped, false) then
    select coalesce('AllBranchFabrication' = any(s."StaffRoles"), false) into v_all_branch_fab
    from public."StaffUsers" s where s."Username" = p_admin_username;
    v_all_branch_fab := coalesce(v_all_branch_fab, false);
  end if;

  if coalesce(p_walkin_only, false) then
    return query
      with buckets(status_label, sort_order) as (
        values ('To Assign', 1), ('Assigned', 2), ('Production Done', 3), ('Completed', 4), ('Shipped', 5), ('Cancelled', 6)
      ),
      order_buckets as (
        select
          case
            when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
            else coalesce(public._walkin_order_stage(o."OrderID"),
                   case when lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2') then 'Shipped' end)
          end as status_label
        from public."OnlineOrders" o
        left join public."Warehouses" w on w."ID" = o."LocationID"
        where o."ReceivedAtShop" is true
          and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name
               or (case when v_all_branch_fab and o."PickedUpAtUtc" is null
                          and (o."Date" >= public._walkin_flow_start()
                               or nullif(trim(coalesce(o."AssignedTankMaker", '')), '') is not null
                               or nullif(trim(coalesce(o."AssignedStandMaker", '')), '') is not null)
                        then public._online_order_open_fabrication(o."OrderID") else false end))
      )
      select b.status_label, count(ob.status_label)::int as order_count
      from buckets b
      left join order_buckets ob on ob.status_label = b.status_label
      group by b.status_label, b.sort_order
      order by b.sort_order;
    return;
  end if;

  return query
    with buckets(status_label, sort_order) as (
      values ('Confirmed', 1), ('Printed', 2), ('Assigned', 3), ('Production Done', 4), ('To Ship', 5), ('Shipped', 6), ('Delivered', 7), ('Cancelled', 8)
    ),
    order_flags as (
      select
        o.*,
        -- Needed makers - only worked out for Printed orders, the one bucket that uses them.
        case when lower(trim(coalesce(o."Status", ''))) = 'printed'
          then public._online_order_assignment_complete(o."OrderID") else false end as all_assigned
      from public."OnlineOrders" o
      left join public."Warehouses" w on w."ID" = o."LocationID"
      where o."ReceivedAtShop" is not true
        and (p_warehouse_name is null or trim(p_warehouse_name) = '' or w."Name" = p_warehouse_name
             or (case when v_all_branch_fab
                        and lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned', 'to ship', 'packing', 'packed')
                   then public._online_order_open_fabrication(o."OrderID") else false end))
    ),
    order_buckets as (
      select
        case
          -- CASE-gated so the done check only runs for open orders (see the list function).
          when case when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted', 'printed', 'assigned')
                 then public._online_order_production_all_done(o."OrderID") else false end then 'Production Done'
          when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted') then 'Confirmed'
          when lower(trim(coalesce(o."Status", ''))) = 'assigned' then 'Assigned'
          when lower(trim(coalesce(o."Status", ''))) = 'printed' then
            case when o.all_assigned then 'Assigned' else 'Printed' end
          when lower(trim(coalesce(o."Status", ''))) in ('to ship', 'packing', 'packed') then 'To Ship'
          when lower(trim(coalesce(o."Status", ''))) in ('shipped', '2') then 'Shipped'
          when lower(trim(coalesce(o."Status", ''))) = 'delivered' then 'Delivered'
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

grant execute on function public.admin_get_online_order_status_summary(text, text, text, boolean, boolean) to anon;

notify pgrst, 'reload schema';
