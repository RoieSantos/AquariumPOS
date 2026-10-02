-- Online Orders: tag each order with the Production Order(s) created for it - per "in the online order..
-- can we tag the production order no. created?".
--
-- The link already exists (ProductionOrders.SourceOnlineOrderId, set by the Online Orders "Assign - build
-- missing units" dialog through staff_link_production_order_to_online_order), but the PRD no. only showed
-- on the next-step button of the selected order while it was Open / Released. This returns every linked
-- production order for the orders on screen so docs/js/onlineOrders.js can show a PRD-xxxxxx badge on each.
--
--   staff_list_online_order_production_orders(order_ids[]) - order_id, production_order_no, status,
--                                                             newest first per order.
--
-- Run AFTER supabase_online_order_stock_ship.sql. Safe to re-run.

drop function if exists public.staff_list_online_order_production_orders(text, text, text[]);

create or replace function public.staff_list_online_order_production_orders(
  p_admin_username text,
  p_admin_password text,
  p_order_ids text[]
)
returns table(order_id text, production_order_no text, status text)
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
    select po."SourceOnlineOrderId"::text, po."No"::text, po."Status"::text
    from public."ProductionOrders" po
    where po."SourceOnlineOrderId" = any(coalesce(p_order_ids, '{}'))
    order by po."SourceOnlineOrderId", po."CreatedAtUtc" desc;
end;
$$;

grant execute on function public.staff_list_online_order_production_orders(text, text, text[]) to anon;

notify pgrst, 'reload schema';
