-- Delivery calendar "Calculate fee": which branch (GMA / Amaya) the truck leaves from, taken from the
-- order's own warehouse - per "dont ask the origin.. the origin should be base on the warehouse
-- location .. dont allow the user to edit this delivery fee and delivery from".
--
-- admin_get_order_delivery_branch(order id, source) -> 'GMA' / 'Amaya' / null (warehouse unknown):
--   online    - OnlineOrders."LocationID" -> Warehouses."Name" (falls back to the AutomatedOrders row a
--               portal AO- order came from, "Location")
--   automated - AutomatedOrders."Location" (Order Form not yet in Pancake)
--   advance   - AdvanceOrders."Warehouse" (order id may come as 'ADV-<TransactionNo>')
-- Matched by name the same way the fee formula finds the origin (public_get_warehouse_location:
-- Warehouses."Name" ilike '%GMA%' / '%Amaya%').
--
-- New function only. Safe to re-run. Needs js/delivery.js ?v=feebranch1.

drop function if exists public.admin_get_order_delivery_branch(text, text, text, text);

create or replace function public.admin_get_order_delivery_branch(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_source text default 'online'
)
returns text
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_id text := trim(coalesce(p_order_id, ''));
  v_name text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_source = 'advance' then
    select a."Warehouse"::text into v_name
    from public."AdvanceOrders" a
    where a."TransactionNo"::text = regexp_replace(v_id, '^ADV-', '');
  elsif p_source = 'automated' then
    select ao."Location"::text into v_name
    from public."AutomatedOrders" ao
    where ao."OrderNo"::text = v_id;
  else
    select coalesce(w."Name"::text, ao."Location"::text) into v_name
    from public."OnlineOrders" o
    left join public."Warehouses" w on w."ID" = o."LocationID"
    left join public."AutomatedOrders" ao on ao."PancakeReceiptNo" = o."OrderID"
    where o."OrderID" = v_id
    limit 1;
  end if;

  return case
    when v_name ilike '%amaya%' then 'Amaya'
    when v_name ilike '%gma%' then 'GMA'
    else null
  end;
end;
$$;

grant execute on function public.admin_get_order_delivery_branch(text, text, text, text) to anon;

notify pgrst, 'reload schema';
