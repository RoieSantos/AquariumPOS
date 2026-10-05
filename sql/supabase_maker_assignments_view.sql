-- Maker Assignments page (maker-assignments.html) - per "create me a new view.. to show all my maker's
-- assignment per maker. this will only be available for super user".
--
-- One list of every OPEN Tank Maker / Stand Maker assignment, from all three places a maker can be
-- assigned:
--   Online / Walk-in - OnlineOrders."AssignedTankMaker" / "AssignedStandMaker" (done = a mark in
--                      OnlineOrderProductionDone by the CURRENT assignee; rework = a send-back in
--                      OnlineOrderProductionRework not yet re-done). Open = status not Shipped /
--                      Delivered / Received / Cancelled (same list as My Assignments).
--   Advance          - AdvanceOrderProduction."TankMaker" / "StandMaker" (done = TankDoneAtUtc /
--                      StandDoneAtUtc; rework = AdvanceOrderRework not fixed). Open = not Shipped.
--   Production       - ProductionOrders."TankMaker" / "StandMaker", only for a part the PO has lines
--                      for (done = TankDoneAtUtc / StandDoneAtUtc; rework = ProductionOrderRework not
--                      fixed). Open = not Finished.
-- part_status per row: 'Rework' (sent back, not done again), 'Pending' (not done) or 'Done' (their
-- part is finished but the order hasn't shipped / finished yet).
--
-- updated_at = when the record was last changed (Advance: AdvanceOrderProduction."UpdatedAtUtc";
-- null for the other sources). Within each maker / part_status, Advance rows sort latest-updated first.
--
-- Active makers (StaffRoles TankMaker / StandMaker) with nothing open are returned once with
-- source = null, so the page can show them as idle.
--
-- Super Users only (is_admin_authorized). Read-only, functions only - no table changes.
-- Run AFTER supabase_online_order_production_rework.sql, supabase_advance_order_production.sql and
-- supabase_production_order_rework.sql. Safe to re-run.

drop function if exists public.admin_list_maker_assignments(text, text);

create or replace function public.admin_list_maker_assignments(p_admin_username text, p_admin_password text)
returns table(
  maker text,
  maker_name text,
  source text,          -- 'Online' / 'Walk-in' / 'Advance' / 'Production'; null = idle maker row
  ref_no text,          -- OrderID / TransactionNo / PO No
  customer text,        -- customer name (PO: its description)
  part text,            -- 'tank' / 'stand'
  part_status text,     -- 'Rework' / 'Pending' / 'Done'
  order_status text,
  warehouse text,
  order_date date,
  done_at timestamptz,
  rework_reason text,
  updated_at timestamptz -- Advance only: AdvanceOrderProduction."UpdatedAtUtc"
)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with a as (
      -- Online / Walk-in orders
      select m.maker, case when o."ReceivedAtShop" is true then 'Walk-in' else 'Online' end as source,
             o."OrderID"::text as ref_no, o."CustomerName"::text as customer, m.part,
             d."DoneAtUtc" as done_at,
             case when d."DoneAtUtc" is null then rw."Reason" end as rework_reason,
             o."Status"::text as order_status, w."Name"::text as warehouse, o."Date" as order_date,
             null::timestamptz as updated_at
      from public."OnlineOrders" o
      cross join lateral (values ('tank', o."AssignedTankMaker"::text), ('stand', o."AssignedStandMaker"::text)) m(part, maker)
      left join public."Warehouses" w on w."ID" = o."LocationID"
      left join public."OnlineOrderProductionDone" d
        on d."OrderID" = o."OrderID" and d."Role" = m.part and d."DoneBy" = m.maker
      left join lateral (
        select r."Reason" from public."OnlineOrderProductionRework" r
        where r."OrderID" = o."OrderID" and r."Role" = m.part
        order by r."SentBackAtUtc" desc limit 1
      ) rw on true
      where nullif(trim(coalesce(m.maker, '')), '') is not null
        and lower(trim(coalesce(o."Status", ''))) not in ('shipped', 'delivered', '2', 'received', '3', 'canceled', 'cancelled')

      union all

      -- Advance orders
      select m.maker, 'Advance', p."TransactionNo"::text, ao."CustomerName"::text, m.part,
             m.done_at,
             case when m.done_at is null then rw."Reason" end,
             public._advance_order_prod_status(p), ao."Warehouse"::text, ao."Date",
             p."UpdatedAtUtc"
      from public."AdvanceOrderProduction" p
      left join public."AdvanceOrders" ao on ao."TransactionNo" = p."TransactionNo"
      cross join lateral (values ('tank', p."TankMaker", p."TankDoneAtUtc"),
                                 ('stand', p."StandMaker", p."StandDoneAtUtc")) m(part, maker, done_at)
      left join lateral (
        select r."Reason" from public."AdvanceOrderRework" r
        where r."TransactionNo" = p."TransactionNo" and r."Part" = m.part and r."FixedAtUtc" is null
        order by r."Id" desc limit 1
      ) rw on true
      where nullif(trim(coalesce(m.maker, '')), '') is not null
        and p."ShippedAtUtc" is null

      union all

      -- Production orders (restock builds) - only a part the PO actually has lines for
      select m.maker, 'Production', po."No"::text, po."Description"::text, m.part,
             m.done_at,
             case when m.done_at is null then rw."Reason" end,
             po."Status"::text, w."Name"::text, coalesce(po."DueDate", (po."CreatedAtUtc" at time zone 'Asia/Manila')::date),
             null::timestamptz
      from public."ProductionOrders" po
      cross join lateral (values ('tank', po."TankMaker"::text, po."TankDoneAtUtc"),
                                 ('stand', po."StandMaker"::text, po."StandDoneAtUtc")) m(part, maker, done_at)
      left join public."Warehouses" w on w."ID" = po."WarehouseId"
      left join lateral (
        select r."Reason" from public."ProductionOrderRework" r
        where r."ProdOrderNo" = po."No" and r."Part" = m.part and r."FixedAtUtc" is null
        order by r."Id" desc limit 1
      ) rw on true
      where nullif(trim(coalesce(m.maker, '')), '') is not null
        and po."Status" <> 'Finished'
        and exists (select 1 from public."ProductionOrderLines" l where l."ProdOrderNo" = po."No" and l."Part" = m.part)
    ),
    x as (
      select a.maker, a.source, a.ref_no, a.customer, a.part,
             case when a.done_at is not null then 'Done'
                  when a.rework_reason is not null then 'Rework'
                  else 'Pending' end as part_status,
             a.order_status, a.warehouse, a.order_date, a.done_at, a.rework_reason, a.updated_at
      from a
      union all
      -- Idle makers: active Tank / Stand Makers with nothing open
      select s."Username"::text, null, null, null, null, null, null, null, null, null, null, null::timestamptz
      from public."StaffUsers" s
      where s."IsActive"
        and coalesce(s."StaffRoles", '{}') && array['TankMaker', 'StandMaker']::text[]
        and not exists (select 1 from a where a.maker = s."Username")
    )
    select r.maker, coalesce(nullif(trim(s."DisplayName"), ''), r.maker)::text,
           r.source, r.ref_no, r.customer, r.part, r.part_status, r.order_status, r.warehouse,
           r.order_date, r.done_at, r.rework_reason, r.updated_at
    from x r
    left join public."StaffUsers" s on s."Username" = r.maker
    order by 2, r.maker,
             case r.part_status when 'Rework' then 0 when 'Pending' then 1 else 2 end,
             -- Advance: latest updated on top; others: oldest order date first
             case when r.source = 'Advance' then r.updated_at end desc nulls last,
             r.order_date nulls last, r.ref_no;
end;
$$;

grant execute on function public.admin_list_maker_assignments(text, text) to anon;

notify pgrst, 'reload schema';
