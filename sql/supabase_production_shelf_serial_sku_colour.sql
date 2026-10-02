-- Production Shelf Map: Black / Clear from the variant SKU - per "why the serials for 2.5 dont show
-- clear sealant sku".
--
-- Serials posted from a Production Order (e.g. PRD-000015's AQ-031 units) carry the right VariantCode,
-- but Supabase's Variants."VariantName" is "<code> - <product name>" (e.g. "AQ-031 - STANDARD-2.5G
-- (12×6×8in, 3MM GLASS)") - no colour - and the order line's description doesn't say it either. The
-- colour only lives in the variant's SKU ("AQ-031-ClearSealant", Pancake's variation display_id), which
-- this RPC never returned, so the rack popup grouped them under the plain variant name instead of
-- Black / Clear. Older serials only worked because their description happened to include the SKU.
--
-- Same RPC as supabase_production_shelf_serial_counts.sql plus a variant_sku column;
-- docs/js/productionShelfMap.js reads the colour from it (and still works before this is run).
--
-- Run AFTER supabase_production_shelf_serial_counts.sql. Safe to re-run.

drop function if exists public.staff_list_production_location_serials(text, text, text);

create or replace function public.staff_list_production_location_serials(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text
)
returns table(running_serial_no bigint, serial_no text, item_code text, item_description text,
              variant_code text, variant_name text, source_document_no text, created_at timestamptz,
              main_item_code text, variant_sku text)
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
           nullif(trim(v."SKU"), '')::text
    from public."ItemSerialTracking" s
    left join public."Items" i on i."Code" = s."ItemCode"
    left join public."Variants" v on v."VariationId" = s."VariantCode"
    where s."Status" = 'IN_STOCK'
      and s."Location" = v_warehouse_name
    order by s."ItemCode", s."SerialNo";
end;
$$;

grant execute on function public.staff_list_production_location_serials(text, text, text) to anon;

notify pgrst, 'reload schema';
