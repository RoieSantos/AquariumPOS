-- Finished Production Orders view (docs/production-orders.html?view=finished, js/productionOrders.js).
-- Per "is it possible to move the finished status of production orders into posted production
-- orders": Finished orders stay in "ProductionOrders" (BC-style - the status is the split, nothing is
-- copied), but get their own list. This lets staff_list_production_orders take p_status = 'Active'
-- (Open + Released - the default on the main Production Orders list, so Finished ones drop off it),
-- and sorts the Finished list newest-finished first.
--
-- Same signature as supabase_production_orders.sql, so create or replace is enough (no drop). That
-- file has the same change, so re-running it won't undo this.

create or replace function public.staff_list_production_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_assigned_to_me boolean default false,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  order_no text, description text, warehouse_id text, warehouse_name text, status text, due_date date, notes text,
  tank_maker text, tank_maker_name text, stand_maker text, stand_maker_name text,
  tank_done_at timestamptz, stand_done_at timestamptz,
  needs_tank boolean, needs_stand boolean,
  line_count int, total_quantity numeric, total_output numeric,
  created_by text, created_at timestamptz, released_at timestamptz, finished_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_manager boolean;
  v_mine boolean;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_status text := nullif(trim(coalesce(p_status, '')), '');
  v_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_offset int := (greatest(coalesce(p_page, 1), 1) - 1) * least(greatest(coalesce(p_page_size, 50), 1), 200);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_manager := public._production_is_manager(p_admin_username);
  v_mine := coalesce(p_assigned_to_me, false) or not v_manager;

  return query
    with agg as (
      select l."ProdOrderNo" as prod_no,
             count(*)::int as line_count,
             sum(l."Quantity") as total_quantity,
             sum(l."QtyOutput") as total_output,
             bool_or(l."Part" = 'tank') as needs_tank,
             bool_or(l."Part" = 'stand') as needs_stand
      from public."ProductionOrderLines" l
      group by l."ProdOrderNo"
    )
    select o."No"::text, o."Description"::text, o."WarehouseId"::text, w."Name"::text, o."Status"::text,
           o."DueDate", o."Notes"::text,
           o."TankMaker"::text, coalesce(nullif(trim(tm."DisplayName"), ''), o."TankMaker")::text,
           o."StandMaker"::text, coalesce(nullif(trim(sm."DisplayName"), ''), o."StandMaker")::text,
           o."TankDoneAtUtc", o."StandDoneAtUtc",
           coalesce(a.needs_tank, false), coalesce(a.needs_stand, false),
           coalesce(a.line_count, 0), coalesce(a.total_quantity, 0), coalesce(a.total_output, 0),
           o."CreatedBy"::text, o."CreatedAtUtc", o."ReleasedAtUtc", o."FinishedAtUtc",
           count(*) over ()
    from public."ProductionOrders" o
    left join agg a on a.prod_no = o."No"
    left join public."Warehouses" w on w."ID" = o."WarehouseId"
    left join public."StaffUsers" tm on tm."Username" = o."TankMaker"
    left join public."StaffUsers" sm on sm."Username" = o."StandMaker"
    where (v_status is null
        or o."Status" = v_status
        or (v_status = 'Active' and o."Status" in ('Open', 'Released')))
      and (not v_mine or (o."Status" = 'Released' and (
            (o."TankMaker" = p_admin_username and coalesce(a.needs_tank, false))
         or (o."StandMaker" = p_admin_username and coalesce(a.needs_stand, false)))))
      and (v_search is null
        or o."No" ilike '%' || v_search || '%'
        or coalesce(o."Description", '') ilike '%' || v_search || '%'
        or exists (select 1 from public."ProductionOrderLines" l
                   where l."ProdOrderNo" = o."No"
                     and (l."ItemCode" ilike '%' || v_search || '%' or coalesce(l."Description", '') ilike '%' || v_search || '%')))
    order by case o."Status" when 'Released' then 0 when 'Open' then 1 else 2 end,
             o."FinishedAtUtc" desc nulls last,
             o."DueDate" nulls last, o."CreatedAtUtc" desc
    limit v_size offset v_offset;
end;
$$;

grant execute on function public.staff_list_production_orders(text, text, text, text, boolean, int, int) to anon;
