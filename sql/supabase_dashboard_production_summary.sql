-- Dashboard "Production" group (super users) - per "dashboards are mostly for reportings... 1st group
-- Sales, 2nd group Production, 3rd group Purchase and Expense and payroll". One read-only summary
-- row for the Production cards in docs/js/dashboard.js's loadProductionSummary.
--
-- Run AFTER supabase_production_orders.sql (ProductionOrders / ProductionOrderOutputs tables).
-- Also admin_get_maker_production_built (per-maker Production Order tasks built) for the
-- dashboard's Maker Assignments table.
-- Safe to re-run (create or replace).

create or replace function public.admin_get_production_dashboard_summary(p_admin_username text, p_admin_password text)
returns table(
  open_count int,
  released_count int,
  overdue_count int,
  finished_month_count int,
  output_month_qty numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date;
  v_month_start date;
  v_month_end date;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_today := (now() at time zone 'Asia/Manila')::date;
  v_month_start := date_trunc('month', v_today)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  return query
    select
      (select count(*) from public."ProductionOrders" where "Status" = 'Open')::int,
      (select count(*) from public."ProductionOrders" where "Status" = 'Released')::int,
      (select count(*) from public."ProductionOrders"
        where "Status" in ('Open', 'Released') and "DueDate" < v_today)::int,
      (select count(*) from public."ProductionOrders"
        where "Status" = 'Finished'
          and ("FinishedAtUtc" at time zone 'Asia/Manila')::date >= v_month_start
          and ("FinishedAtUtc" at time zone 'Asia/Manila')::date < v_month_end)::int,
      (select coalesce(sum("Quantity"), 0) from public."ProductionOrderOutputs"
        where ("PostedAtUtc" at time zone 'Asia/Manila')::date >= v_month_start
          and ("PostedAtUtc" at time zone 'Asia/Manila')::date < v_month_end)::numeric;
end;
$$;

grant execute on function public.admin_get_production_dashboard_summary(text, text) to anon;

-- Per "in the maker view can we show the no. of task build on production order as well" - per
-- maker, the Production Order parts (tasks) they finished: one task = one part (tank or stand) of
-- one production order, counted when its TankDoneAtUtc / StandDoneAtUtc is set. units = the
-- quantity on that order's lines for that part. maker = the same username key as
-- admin_list_maker_assignments, so docs/js/dashboard.js joins the two on it.
create or replace function public.admin_get_maker_production_built(p_admin_username text, p_admin_password text)
returns table(
  maker text,
  tasks_month int,
  units_month numeric,
  tasks_total int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  return query
    with parts as (
      select po."No" as order_no, po."TankMaker"::text as maker, 'tank'::text as part, po."TankDoneAtUtc" as done_at
        from public."ProductionOrders" po
        where po."TankMaker" is not null and po."TankDoneAtUtc" is not null
      union all
      select po."No", po."StandMaker"::text, 'stand', po."StandDoneAtUtc"
        from public."ProductionOrders" po
        where po."StandMaker" is not null and po."StandDoneAtUtc" is not null
    ),
    parts_qty as (
      select p.*,
        (p.done_at at time zone 'Asia/Manila')::date >= v_month_start
          and (p.done_at at time zone 'Asia/Manila')::date < v_month_end as in_month,
        coalesce((select sum(l."Quantity") from public."ProductionOrderLines" l
                   where l."ProdOrderNo" = p.order_no and l."Part" = p.part), 0) as qty
      from parts p
    )
    select
      q.maker,
      (count(*) filter (where q.in_month))::int,
      coalesce(sum(q.qty) filter (where q.in_month), 0)::numeric,
      count(*)::int
    from parts_qty q
    group by q.maker;
end;
$$;

grant execute on function public.admin_get_maker_production_built(text, text) to anon;
