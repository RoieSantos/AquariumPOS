-- Alice (Portal Chat only): maker names on an order's production progress - per "can we teach Alice to
-- know who is the maker name of an order but not Vic" / "yes correct inside the portal".
--
-- staff_get_online_order_production(order_id) - same rows as public_get_online_order_production
-- (supabase_chatbot_order_production_progress.sql) plus maker_username / maker_name for each part.
-- Called by get_order_status (chatbot-engine.ts) ONLY when the conversation is portal-chat:... (internal
-- staff); Messenger (Vic), the website widget and the AI Bot Sandbox keep the name-free public function.
--
-- NOT granted to anon - only service_role (the portal-chat-alice-reply Edge Function), so staff names
-- can't be pulled from the public API.
--
-- Run AFTER supabase_chatbot_order_production_progress.sql. Safe to re-run.

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
      and o."ReceivedAtShop" is not true
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
