-- Production Shelf Map: AUTO PRODUCTION ORDER - per "in the production shelf map can we auto populate
-- the production order base on what we are lacking quantity?".
--
-- The page (docs/js/productionShelfMap.js) works out each linked aquarium's shortfall at the location:
--   short = SUM(rack Capacity) - IN_STOCK serials - still to be built on Open/Released orders
-- and creates a production order for it with the existing staff_save_production_order.
--
-- This adds the one thing the page can't see: what's already on order and not yet output, so
-- pressing the button twice doesn't order the same tanks twice.
--
--   staff_list_production_open_qty(user, pass, warehouse) -> item_code, variant_id, main_item_code,
--     open_qty (Quantity - QtyOutput summed over Open/Released orders into that warehouse).
--
-- Run AFTER supabase_production_orders.sql. Safe to re-run.

drop function if exists public.staff_list_production_open_qty(text, text, text);

create or replace function public.staff_list_production_open_qty(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text
)
returns table(item_code text, variant_id text, main_item_code text, open_qty numeric)
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
    select l."ItemCode"::text, l."VariantId"::text, nullif(trim(v."MainItemCode"), '')::text,
           sum(l."Quantity" - l."QtyOutput")
    from public."ProductionOrderLines" l
    join public."ProductionOrders" o on o."No" = l."ProdOrderNo"
    left join public."Variants" v on v."VariationId" = l."VariantId"
    where o."WarehouseId" = p_warehouse_id
      and o."Status" in ('Open', 'Released')
      and l."Quantity" > l."QtyOutput"
    group by l."ItemCode", l."VariantId", v."MainItemCode";
end;
$$;

grant execute on function public.staff_list_production_open_qty(text, text, text) to anon;

notify pgrst, 'reload schema';
