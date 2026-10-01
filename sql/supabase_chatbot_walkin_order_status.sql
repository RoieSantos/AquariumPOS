-- Alice: read walk-in orders too - per "can you teach ai-bot to be able to read on the walk-in orders as well?".
--
-- Before, every get_order_status RPC skipped ReceivedAtShop = true, so a walk-in customer asking "is my
-- custom tank done yet?" got "No order found". Now:
--
--   public_get_online_order_status(order_id_or_receipt)
--     - also finds walk-ins (ReceivedAtShop = true), by Pancake OrderID OR by the POS receipt no. the
--       customer actually holds (e.g. RS-0000010861 - the first word of OnlineOrders."Note", see
--       supabase_walkin_order_pos_note.sql). Receipt match is case-insensitive.
--     - order_id is always the real OrderID, so the engine looks up lines / production with it.
--     - new columns: order_type ('Online Order' / 'Walk-in Order') and target_ready_date (walk-ins only:
--       the portal-only WalkinDueDate set when every maker is assigned).
--     - walk-in status_label = its portal stage (_walkin_order_stage: To Assign / Assigned /
--       Production Done / Completed); a walk-in outside the maker flow (plain in-store sale, or an old
--       custom walk-in nobody assigned) = 'Completed' - it was paid for and handed over at the counter.
--       Pancake's own "Shipped" is never shown for a walk-in (it means nothing to the customer).
--     - still no customer name / phone / address (walk-in name / contact no. included).
--
--   public_get_online_order_production / staff_get_online_order_production
--     - also return rows for a walk-in IN the maker flow (_walkin_order_stage not null). Walk-ins
--       outside the flow still return nothing, so the 2,500+ old custom walk-ins never read as
--       "queued, waiting for a maker".
--
-- public_get_online_order_lines is unchanged (it never filtered walk-ins). The receipt page
-- (public_get_online_order_receipt) still excludes walk-ins - the engine doesn't offer receiptUrl for them.
--
-- Run AFTER supabase_walkin_order_portal_status.sql, supabase_walkin_order_pos_note.sql and
-- supabase_chatbot_order_production_maker_names.sql. Safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Status (header)
-- ---------------------------------------------------------------------------
drop function if exists public.public_get_online_order_status(text);

create or replace function public.public_get_online_order_status(p_order_id text)
returns table(
  order_id text,
  order_type text,
  status_label text,
  warehouse_name text,
  money_to_collect numeric,
  balance numeric,
  target_ready_date date
)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with hit as (
    -- Exact OrderID first (online or walk-in); else a walk-in whose POS receipt no. matches.
    select o.*
    from public."OnlineOrders" o
    where o."OrderID" = trim(p_order_id)
    union all
    select * from (
      select o.*
      from public."OnlineOrders" o
      where o."ReceivedAtShop" is true
        and nullif(trim(p_order_id), '') is not null
        and upper(split_part(trim(coalesce(o."Note", '')), ' ', 1)) = upper(trim(p_order_id))
        and not exists (select 1 from public."OnlineOrders" x where x."OrderID" = trim(p_order_id))
      order by o."Date" desc nulls last
      limit 1
    ) r
  )
  select
    o."OrderID"::text,
    case when o."ReceivedAtShop" is true then 'Walk-in Order' else 'Online Order' end,
    case
      when o."ReceivedAtShop" is true then
        case
          when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
          else coalesce(public._walkin_order_stage(o."OrderID"), 'Completed')
        end
      else coalesce(
        case
          when lower(trim(coalesce(o."Status", ''))) in ('confirmed', 'submitted') then 'Confirmed'
          when lower(trim(coalesce(o."Status", ''))) = 'printed' then 'Printed'
          when lower(trim(coalesce(o."Status", ''))) in ('to ship', 'packing', 'packed') then 'To Ship'
          when lower(trim(coalesce(o."Status", ''))) in ('shipped', 'delivered', '2') then 'Shipped'
          when lower(trim(coalesce(o."Status", ''))) in ('canceled', 'cancelled') then 'Cancelled'
          else null
        end,
        o."Status"
      )
    end::text,
    coalesce(w."Name"::text, o."LocationID"::text),
    o."MoneyToCollect",
    o."Balance",
    case when o."ReceivedAtShop" is true then o."WalkinDueDate" end
  from hit o
  left join public."Warehouses" w on w."ID" = o."LocationID";
$$;

grant execute on function public.public_get_online_order_status(text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Production progress (no names) - same as supabase_chatbot_order_production_progress.sql, plus
--    walk-ins in the maker flow.
-- ---------------------------------------------------------------------------
drop function if exists public.public_get_online_order_production(text);

create or replace function public.public_get_online_order_production(p_order_id text)
returns table(
  source text,
  part text,
  assigned boolean,
  done boolean,
  done_at timestamptz,
  build_status text,
  qty numeric,
  qty_built numeric
)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with ord as (
    select o.*
    from public."OnlineOrders" o
    where o."OrderID" = trim(p_order_id)
      and (o."ReceivedAtShop" is not true or public._walkin_order_stage(o."OrderID") is not null)
  )
  select 'order'::text,
         r.role::text,
         (case r.role when 'tank' then ord."AssignedTankMaker" when 'stand' then ord."AssignedStandMaker"
                      else ord."AssignedDispatcher" end) is not null,
         d."DoneAtUtc" is not null,
         d."DoneAtUtc",
         null::text,
         null::numeric,
         null::numeric
  from ord
  cross join lateral unnest(public._online_order_production_roles(ord."OrderID")) as r(role)
  left join public."OnlineOrderProductionDone" d
    on d."OrderID" = ord."OrderID" and d."Role" = r.role
   and d."DoneBy" = case r.role when 'tank' then ord."AssignedTankMaker" when 'stand' then ord."AssignedStandMaker"
                                else ord."AssignedDispatcher" end

  union all

  select 'production_order'::text,
         l."Part"::text,
         (case l."Part" when 'tank' then po."TankMaker" else po."StandMaker" end) is not null,
         (case l."Part" when 'tank' then po."TankDoneAtUtc" else po."StandDoneAtUtc" end) is not null,
         case l."Part" when 'tank' then po."TankDoneAtUtc" else po."StandDoneAtUtc" end,
         po."Status"::text,
         sum(l."Quantity"),
         sum(l."QtyOutput")
  from ord
  join public."ProductionOrders" po on po."SourceOnlineOrderId" = ord."OrderID"
  join public."ProductionOrderLines" l on l."ProdOrderNo" = po."No"
  group by po."No", po."Status", po."CreatedAtUtc", l."Part", po."TankMaker", po."StandMaker", po."TankDoneAtUtc", po."StandDoneAtUtc";
$$;

grant execute on function public.public_get_online_order_production(text) to anon;

-- ---------------------------------------------------------------------------
-- 3. Production progress WITH maker names (Portal Chat only, service_role) - same as
--    supabase_chatbot_order_production_maker_names.sql, plus walk-ins in the maker flow.
-- ---------------------------------------------------------------------------
drop function if exists public.staff_get_online_order_production(text);

create or replace function public.staff_get_online_order_production(p_order_id text)
returns table(
  source text,
  part text,
  assigned boolean,
  done boolean,
  done_at timestamptz,
  build_status text,
  qty numeric,
  qty_built numeric,
  maker_username text,
  maker_name text
)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with ord as (
    select o.*
    from public."OnlineOrders" o
    where o."OrderID" = trim(p_order_id)
      and (o."ReceivedAtShop" is not true or public._walkin_order_stage(o."OrderID") is not null)
  ),
  order_parts as (
    select r.role::text as part,
           (case r.role when 'tank' then ord."AssignedTankMaker" when 'stand' then ord."AssignedStandMaker"
                        else ord."AssignedDispatcher" end)::text as maker,
           ord."OrderID"
    from ord
    cross join lateral unnest(public._online_order_production_roles(ord."OrderID")) as r(role)
  ),
  po_parts as (
    select l."Part"::text as part,
           (case l."Part" when 'tank' then po."TankMaker" else po."StandMaker" end)::text as maker,
           case l."Part" when 'tank' then po."TankDoneAtUtc" else po."StandDoneAtUtc" end as done_at,
           po."Status"::text as build_status,
           sum(l."Quantity") as qty,
           sum(l."QtyOutput") as qty_built
    from ord
    join public."ProductionOrders" po on po."SourceOnlineOrderId" = ord."OrderID"
    join public."ProductionOrderLines" l on l."ProdOrderNo" = po."No"
    group by po."No", po."Status", po."CreatedAtUtc", l."Part", po."TankMaker", po."StandMaker", po."TankDoneAtUtc", po."StandDoneAtUtc"
  )
  select 'order'::text,
         p.part,
         p.maker is not null,
         d."DoneAtUtc" is not null,
         d."DoneAtUtc",
         null::text,
         null::numeric,
         null::numeric,
         p.maker,
         su."DisplayName"::text
  from order_parts p
  left join public."OnlineOrderProductionDone" d
    on d."OrderID" = p."OrderID" and d."Role" = p.part and d."DoneBy" = p.maker
  left join public."StaffUsers" su on su."Username" = p.maker

  union all

  select 'production_order'::text,
         p.part,
         p.maker is not null,
         p.done_at is not null,
         p.done_at,
         p.build_status,
         p.qty,
         p.qty_built,
         p.maker,
         su."DisplayName"::text
  from po_parts p
  left join public."StaffUsers" su on su."Username" = p.maker;
$$;

revoke all on function public.staff_get_online_order_production(text) from public, anon, authenticated;
grant execute on function public.staff_get_online_order_production(text) to service_role;

notify pgrst, 'reload schema';

-- Check (read-only): the latest walk-ins in the maker flow, looked up the way Alice will.
-- select o."OrderID", split_part(o."Note", ' ', 1) as receipt_no, s.*
-- from public."OnlineOrders" o
-- cross join lateral public.public_get_online_order_status(split_part(o."Note", ' ', 1)) s
-- where o."ReceivedAtShop" is true and o."Date" >= public._walkin_flow_start()
-- order by o."Date" desc limit 10;
