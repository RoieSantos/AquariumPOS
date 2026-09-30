-- Fix: STANDARD aquariums were landing on the Stand order.
-- The Stand Maker rule was "name/code contains 'stand' or 'top cover'", and "STANDARD-50G ..." contains
-- "stand". Now 'stand' only counts when it isn't the start of "standard".
-- Same change is in supabase_production_orders.sql / supabase_online_order_maker_line_rules.sql and the
-- portal JS (productionShelfMap.js, productionOrders.js, onlineOrders.js). Functions + a data fix only.

create or replace function public._production_line_part(p_description text, p_item_code text)
returns text
language sql
immutable
as $$
  select case
    when (coalesce(p_description, '') || ' ' || coalesce(p_item_code, '')) ~* '(stand(?!ard)|top[[:space:]_-]*cover)' then 'stand'
    else 'tank'
  end;
$$;

revoke execute on function public._production_line_part(text, text) from public, anon, authenticated;

create or replace function public._online_order_line_part(p_description text, p_item_code text, p_product_display_id text)
returns text
language sql
immutable
as $$
  select case
    when not (coalesce(p_description, '') ilike '%custom%' or coalesce(p_item_code, '') ilike '%custom%'
              or coalesce(p_product_display_id, '') ilike '%custom%') then null
    when (coalesce(p_description, '') || ' ' || coalesce(p_item_code, '')) ~* '(stand(?!ard)|top[[:space:]_-]*cover)' then 'stand'
    else 'tank'
  end;
$$;

revoke execute on function public._online_order_line_part(text, text, text) from public, anon, authenticated;

-- Re-tag lines already saved as 'stand' by the old rule, on orders not finished yet.
update public."ProductionOrderLines" l
set "Part" = 'tank'
from public."ProductionOrders" o
where o."No" = l."ProdOrderNo"
  and o."Status" in ('Open', 'Released')
  and l."Part" = 'stand'
  and public._production_line_part(l."Description", l."ItemCode") = 'tank';

-- CHECK (run on its own): open/released orders that now have tank lines but no Tank Maker.
-- select o."No", o."Description", o."Status", o."StandMaker", count(*) as tank_lines
-- from public."ProductionOrders" o
-- join public."ProductionOrderLines" l on l."ProdOrderNo" = o."No" and l."Part" = 'tank'
-- where o."Status" in ('Open', 'Released') and o."TankMaker" is null
-- group by o."No", o."Description", o."Status", o."StandMaker";
