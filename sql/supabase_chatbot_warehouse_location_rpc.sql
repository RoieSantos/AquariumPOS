-- AI Messenger chatbot: branch address/coordinates lookup, called by the compute_delivery_quote
-- tool (supabase/functions/facebook-messenger-webhook) to get an origin point for Google's Routes
-- API distance calculation.
--
-- public."Warehouses" already stores geocoded Address/Latitude/Longitude per branch
-- (sql/supabase_warehouses_items_tables.sql:48-53), used today by
-- _push_automated_order_to_pancake to resolve "Amaya"/"GMA" by name
-- (sql/supabase_automated_orders_tables.sql). No anon RPC exposes it yet - this is a narrow slice
-- (just address/lat/lng for the two named branches), same non-sensitive exposure class as
-- public."CompanyInfo".Address (a public store address, not internal warehouse operational data).

drop function if exists public.public_get_warehouse_location(text);

create or replace function public.public_get_warehouse_location(p_location text)
returns table(address text, latitude numeric, longitude numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "Address"::text, "Latitude", "Longitude"
  from public."Warehouses"
  where "IsActive" is true
    and "Name" ilike '%' || p_location || '%'
    and "Latitude" is not null and "Longitude" is not null
  order by "Name"
  limit 1;
$$;

grant execute on function public.public_get_warehouse_location(text) to anon;
