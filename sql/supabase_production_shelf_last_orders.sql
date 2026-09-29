-- Production Shelf Map: LAST PRODUCTION ORDER per maker part - per "in the production shelf map can you
-- show what is the last production order created for Tank and Stand maker".
--
--   staff_get_last_production_orders(user, pass, warehouse) -> one row per part ('tank' / 'stand'):
--     the most recently CREATED production order into that warehouse that has a line of that part
--     (Open, Released or Finished), with its status, maker, quantities and dates.
--
-- The page (docs/js/productionShelfMap.js) shows them in a strip above the map for the location on
-- screen, linking to the order on Production Orders.
--
-- Run AFTER supabase_production_orders.sql. Safe to re-run.

drop function if exists public.staff_get_last_production_orders(text, text, text);

create or replace function public.staff_get_last_production_orders(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text
)
returns table(part text, order_no text, description text, status text, created_at timestamptz,
              created_by text, due_date date, maker text, maker_name text, part_done_at timestamptz,
              total_quantity numeric, total_output numeric)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select p.part, o."No"::text, o."Description"::text, o."Status"::text, o."CreatedAtUtc",
           o."CreatedBy"::text, o."DueDate",
           (case p.part when 'tank' then o."TankMaker" else o."StandMaker" end)::text,
           coalesce(nullif(trim(su."DisplayName"), ''), case p.part when 'tank' then o."TankMaker" else o."StandMaker" end)::text,
           case p.part when 'tank' then o."TankDoneAtUtc" else o."StandDoneAtUtc" end,
           q.qty, q.output
    from (values ('tank'), ('stand')) as p(part)
    cross join lateral (
      select o2.*
      from public."ProductionOrders" o2
      where o2."WarehouseId" = p_warehouse_id
        and exists (select 1 from public."ProductionOrderLines" l
                    where l."ProdOrderNo" = o2."No" and l."Part" = p.part)
      order by o2."CreatedAtUtc" desc, o2."No" desc
      limit 1
    ) o
    cross join lateral (
      select sum(l."Quantity") as qty, sum(l."QtyOutput") as output
      from public."ProductionOrderLines" l
      where l."ProdOrderNo" = o."No" and l."Part" = p.part
    ) q
    left join public."StaffUsers" su
      on su."Username" = case p.part when 'tank' then o."TankMaker" else o."StandMaker" end;
end;
$$;

grant execute on function public.staff_get_last_production_orders(text, text, text) to anon;

notify pgrst, 'reload schema';
