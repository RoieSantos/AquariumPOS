-- Production Shelf Map: racks linked to one variant show its SKU / Black-Clear tag, and the 75g rack
-- goes back to "Any variant" - per "next we would need to update the production shelf map and be
-- consistent".
--
-- Why the 75g rack showed "Black 3" only: it was linked to ONE variant of AQ-028 (the Black one), so it
-- only counted that variant's serials - every other rack is "Any variant" and shows Black + Clear. The
-- rack face couldn't tell you that, because both AQ-028 variants have the same VariantName
-- ("AQ-028 - STANDARD-75G (...)") - only the SKU ("AQ-028-BlackSealant") says which.
--
--   1. staff_get_production_shelves - same as supabase_production_shelf_count_source.sql, except a
--      rack's variant_name prefers the SKU and a new variant_colour says Black / Clear.
--   2. One-off: unlink AQ-028 racks from a single variant so they count Black + Clear like the rest.
--
-- Run AFTER supabase_production_shelf_count_source.sql and supabase_production_variant_colour.sql
-- (for _production_colour). Safe to re-run.

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

-- One-off: the 75g (AQ-028) rack -> "Any variant", same as every other rack.
update public."ProductionShelfSpots"
   set "VariantId" = null
 where "ItemCode" = 'AQ-028'
   and "VariantId" is not null;

notify pgrst, 'reload schema';
