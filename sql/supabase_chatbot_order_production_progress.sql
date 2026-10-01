-- Alice: production progress per part on an order - per "can alice know the status of the order? lets say
-- for example the order has been assigned then the tank maker is done but the stand is not yet done" /
-- "no names involve just stand and tank maker should do".
--
-- public_get_online_order_production(order_id) - anon, called by get_order_status (chatbot-engine.ts) right
-- after public_get_online_order_status finds the order. One row per part, NO staff names / usernames:
--
--   source = 'order'            - the online order's own maker flow (custom lines,
--                                 supabase_online_order_production_done.sql). One row per part the order
--                                 needs (_online_order_production_roles: tank / stand / dispatcher).
--                                 assigned = that role has an assignee on the order;
--                                 done     = OnlineOrderProductionDone row whose DoneBy is still that role's
--                                            assignee (same rule the portal uses - reassigning or Send Back
--                                            clears it).
--   source = 'production_order' - a Production Order built for this order (ProductionOrders.SourceOnlineOrderId),
--                                 one row per part on it. build_status = Open (queued, not yet handed to the
--                                 makers) / Released (being built) / Finished; assigned = maker set;
--                                 done = the maker's Production Done (TankDoneAtUtc / StandDoneAtUtc);
--                                 qty / qty_built = that part's line quantity vs. output posted.
--
-- Nothing returned for an order that isn't found, was received at the shop, or needs no production.
--
-- Run AFTER supabase_online_order_maker_line_rules.sql and supabase_online_order_stock_ship.sql. Safe to re-run.

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
      and o."ReceivedAtShop" is not true
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

notify pgrst, 'reload schema';
