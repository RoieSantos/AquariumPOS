-- Production Shelf Map: reserved units show on their rack - per "if we check on the production shelf map
-- will the stocks show reserve?".
--
-- staff_list_production_location_serials only returned IN_STOCK serials, so a unit RESERVED for an order
-- (supabase_serial_order_reservation.sql - built for that order, still physically on the rack) vanished
-- from the map as if it wasn't there. Now it also returns RESERVED serials at the location, with status
-- and reserved_for_order_id; docs/js/productionShelfMap.js keeps the rack's count / Available / Low / Out
-- on the units free to sell and shows "+ n reserved" beside it (rack, stock card, rack popup lists them
-- with their order). Auto Order is unchanged: reserved units are leaving with their order, so they don't
-- count toward the rack being full.
--
-- Same RPC as supabase_production_shelf_serial_sku_colour.sql plus two columns (dropped and re-created) -
-- don't re-run that file afterwards. Read-only, safe to re-run. Needs productionShelfMap.js ?v=26.

drop function if exists public.staff_list_production_location_serials(text, text, text);

create or replace function public.staff_list_production_location_serials(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text
)
returns table(running_serial_no bigint, serial_no text, item_code text, item_description text,
              variant_code text, variant_name text, source_document_no text, created_at timestamptz,
              main_item_code text, variant_sku text, status text, reserved_for_order_id text)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_warehouse_name text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  select "Name" into v_warehouse_name from public."Warehouses" where "ID" = p_warehouse_id;
  if v_warehouse_name is null then
    return;
  end if;

  return query
    select s."RunningSerialNo", s."SerialNo"::text, s."ItemCode"::text,
           coalesce(s."ItemDescription", i."Name")::text, s."VariantCode"::text,
           coalesce(nullif(trim(v."VariantName"), ''), v."SKU")::text,
           s."SourceDocumentNo"::text, s."CreatedAtUtc",
           nullif(trim(v."MainItemCode"), '')::text,
           nullif(trim(v."SKU"), '')::text,
           s."Status"::text,
           case when s."Status" = 'RESERVED' then s."ReservedForOrderId"::text end
    from public."ItemSerialTracking" s
    left join public."Items" i on i."Code" = s."ItemCode"
    left join public."Variants" v on v."VariationId" = s."VariantCode"
    where s."Status" in ('IN_STOCK', 'RESERVED')
      and s."Location" = v_warehouse_name
    order by s."ItemCode", s."SerialNo";
end;
$$;

grant execute on function public.staff_list_production_location_serials(text, text, text) to anon;


notify pgrst, 'reload schema';

-- Verification - one result.
select p.proname::text as function_name, pg_get_function_result(p.oid) as returns
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'staff_list_production_location_serials';
