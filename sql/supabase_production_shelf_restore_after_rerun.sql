-- Fix: Production Shelf Map shows "No racks at this location are linked to a product yet" (2026-10-24).
--
-- Cause: supabase_production_shelf_map.sql was re-run (supabase_production_orders_rerun_fix.sql said to,
-- for staff_list_production_order_serials' shelf_spot). That file is the ORIGINAL shelf map, so it also
-- re-created the oldest staff_get_production_shelves - no rack aquarium link (item_code), size tag,
-- floor-plan position or count source - and an old 6-argument admin_save_production_shelf beside the
-- current 7-argument one. The racks themselves are fine (37 linked at Amaya and GMA).
--
-- This file:
--   1. re-creates staff_get_production_shelves exactly as supabase_production_shelf_rack_variant_sku.sql
--      (the newest version - without that file's one-off AQ-028 update);
--   2. drops the old 6-argument admin_save_production_shelf (the page calls the 7-argument one with p_layout).
-- staff_list_production_order_serials keeps the shelf_spot the re-run gave it.
--
-- Don't Edit Layout > Save on the shelf map until this is run - the page's draft has no aquarium links.
-- Safe to re-run. Ends with ONE result: OK / FIX per item.

drop function if exists public.staff_get_production_shelves(text, text);

create or replace function public.staff_get_production_shelves(p_admin_username text, p_admin_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', sh."Id",
      'name', sh."Name",
      'layout', sh."Layout",
      'warehouse_id', sh."WarehouseId",
      'warehouse_name', w."Name",
      'spots', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', sp."Id",
          'row_no', sp."RowNo",
          'col_no', sp."ColNo",
          'label', sp."Label",
          'capacity', sp."Capacity",
          'notes', sp."Notes",
          'pos_x', sp."PosX",
          'pos_y', sp."PosY",
          'width', sp."Width",
          'height', sp."Height",
          'size_tag', sp."SizeTag",
          'item_code', sp."ItemCode",
          'item_name', ti."Name",
          'variant_id', sp."VariantId",
          'variant_name', coalesce(nullif(trim(tv."SKU"), ''), nullif(trim(tv."VariantName"), '')),
          'variant_colour', public._production_colour(tv."VariantName", tv."SKU", tvi."Name"),
          'count_source', coalesce(sp."CountSource", 'serials'),
          'serials', coalesce((
            select jsonb_agg(jsonb_build_object(
              'running_serial_no', s."RunningSerialNo",
              'serial_no', s."SerialNo",
              'item_code', s."ItemCode",
              'item_description', coalesce(s."ItemDescription", i."Name"),
              'variant_code', s."VariantCode",
              'variant_name', coalesce(nullif(trim(v."VariantName"), ''), v."SKU"),
              'source_document_no', s."SourceDocumentNo",
              'placed_at', p."PlacedAtUtc",
              'placed_by', p."PlacedBy"
            ) order by s."ItemCode", s."SerialNo")
            from public."_ProductionShelfPlacements" p
            join public."ItemSerialTracking" s on s."RunningSerialNo" = p."RunningSerialNo"
            left join public."Items" i on i."Code" = s."ItemCode"
            left join public."Variants" v on v."VariationId" = s."VariantCode"
            where p."SpotId" = sp."Id"
          ), '[]'::jsonb)
        ) order by sp."RowNo", sp."ColNo")
        from public."ProductionShelfSpots" sp
        left join public."Items" ti on ti."Code" = sp."ItemCode"
        left join public."Variants" tv on tv."VariationId" = sp."VariantId"
        left join public."Items" tvi on tvi."Code" = tv."ItemCode"
        where sp."ShelfId" = sh."Id"
      ), '[]'::jsonb)
    ) order by sh."SortOrder", sh."Id")
    from public."ProductionShelves" sh
    left join public."Warehouses" w on w."ID" = sh."WarehouseId"
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.staff_get_production_shelves(text, text) to anon;

drop function if exists public.admin_save_production_shelf(text, text, int, text, text, jsonb);

notify pgrst, 'reload schema';

select 'staff_get_production_shelves returns rack item_code' as check_name,
       case when bool_or(pg_get_functiondef(p.oid) ilike '%''item_code'', sp."ItemCode"%') then 'OK' else 'FIX' end as result
from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
where p.proname = 'staff_get_production_shelves'
union all
select 'admin_save_production_shelf - one version, with p_layout',
       case when count(*) = 1 and bool_and(pg_get_function_arguments(p.oid) ilike '%p_layout%') then 'OK'
            else 'FIX (' || count(*) || ' versions)' end
from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
where p.proname = 'admin_save_production_shelf';
