-- Production Shelf Map: SIZE TAG per spot - per "in this view i want to be able to tag per aquarium
-- size.. let say for example B4 is 75g, B3 is 50g".
--
-- Each spot gets:
--   SizeTag   - short free text shown as a badge on the rack (e.g. "75g", "50g", "4ft stand").
--   ItemCode / VariantId (optional) - the actual item/variant that belongs there. When set, the spot's
--               "put a unit here" suggestions list matching units first, and the page asks before
--               putting a different item on it. Not enforced here - a mixed rack is sometimes real.
-- Find on the page also matches the tag, so typing "75g" highlights the 75g rack.
--
-- Run AFTER supabase_production_shelf_floor_plan.sql (re-creates its two functions with the new
-- fields). Safe to re-run.

alter table public."ProductionShelfSpots" add column if not exists "SizeTag" varchar(50);
alter table public."ProductionShelfSpots" add column if not exists "ItemCode" varchar(200);
alter table public."ProductionShelfSpots" add column if not exists "VariantId" varchar(100);

-- ============================================================================
-- Reading - same as supabase_production_shelf_floor_plan.sql plus the tag / item
-- ============================================================================

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
          'variant_name', coalesce(nullif(trim(tv."VariantName"), ''), tv."SKU"),
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
        where sp."ShelfId" = sh."Id"
      ), '[]'::jsonb)
    ) order by sh."SortOrder", sh."Id")
    from public."ProductionShelves" sh
    left join public."Warehouses" w on w."ID" = sh."WarehouseId"
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.staff_get_production_shelves(text, text) to anon;

-- ============================================================================
-- Saving - adds each spot's size_tag / item_code / variant_id
-- ============================================================================

drop function if exists public.admin_save_production_shelf(text, text, int, text, text, jsonb, text);

create or replace function public.admin_save_production_shelf(
  p_admin_username text,
  p_admin_password text,
  p_id int,
  p_name text,
  p_warehouse_id text,
  p_spots jsonb,
  p_layout text default 'grid'
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id int := p_id;
  v_layout text := case when lower(coalesce(p_layout, '')) = 'floor' then 'floor' else 'grid' end;
  v_spot jsonb;
  v_spot_id int;
  v_keep int[] := '{}';
  v_item text;
  v_variant text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can edit production shelves.';
  end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'Shelf name is required.';
  end if;
  if not exists (select 1 from public."Warehouses" where "ID" = p_warehouse_id) then
    raise exception 'Pick the warehouse this shelf is in.';
  end if;

  if v_id is null then
    insert into public."ProductionShelves" ("Name", "WarehouseId", "SortOrder", "Layout")
    values (trim(p_name), p_warehouse_id, coalesce((select max("SortOrder") + 1 from public."ProductionShelves"), 0), v_layout)
    returning "Id" into v_id;
  else
    if exists (select 1 from public."ProductionShelves" where "Id" = v_id and "WarehouseId" <> p_warehouse_id)
       and exists (select 1 from public."_ProductionShelfPlacements" where "ShelfId" = v_id) then
      raise exception 'This shelf has serials on it - take them off before moving it to another warehouse.';
    end if;
    update public."ProductionShelves" set "Name" = trim(p_name), "WarehouseId" = p_warehouse_id, "Layout" = v_layout where "Id" = v_id;
    if not found then
      raise exception 'Shelf not found.';
    end if;
  end if;

  for v_spot in select * from jsonb_array_elements(coalesce(p_spots, '[]'::jsonb))
  loop
    v_spot_id := nullif(v_spot->>'id', '')::int;
    v_item := nullif(trim(coalesce(v_spot->>'item_code', '')), '');
    v_variant := case when v_item is null then null else nullif(trim(coalesce(v_spot->>'variant_id', '')), '') end;
    if v_item is not null and not exists (select 1 from public."Items" where "Code" = v_item) then
      raise exception 'Spot %: item "%" does not exist.', coalesce(nullif(v_spot->>'label', ''), '?'), v_item;
    end if;

    if v_spot_id is not null and exists (select 1 from public."ProductionShelfSpots" where "Id" = v_spot_id and "ShelfId" = v_id) then
      update public."ProductionShelfSpots"
        set "RowNo" = (v_spot->>'row_no')::int, "ColNo" = (v_spot->>'col_no')::int,
            "Label" = coalesce(trim(v_spot->>'label'), ''),
            "Capacity" = nullif(v_spot->>'capacity', '')::int,
            "Notes" = nullif(trim(coalesce(v_spot->>'notes', '')), ''),
            "PosX" = nullif(v_spot->>'pos_x', '')::numeric,
            "PosY" = nullif(v_spot->>'pos_y', '')::numeric,
            "Width" = nullif(v_spot->>'width', '')::numeric,
            "Height" = nullif(v_spot->>'height', '')::numeric,
            "SizeTag" = nullif(trim(coalesce(v_spot->>'size_tag', '')), ''),
            "ItemCode" = v_item,
            "VariantId" = v_variant
        where "Id" = v_spot_id;
    else
      insert into public."ProductionShelfSpots" ("ShelfId", "RowNo", "ColNo", "Label", "Capacity", "Notes", "PosX", "PosY", "Width", "Height",
                                                 "SizeTag", "ItemCode", "VariantId")
      values (v_id, (v_spot->>'row_no')::int, (v_spot->>'col_no')::int, coalesce(trim(v_spot->>'label'), ''),
              nullif(v_spot->>'capacity', '')::int, nullif(trim(coalesce(v_spot->>'notes', '')), ''),
              nullif(v_spot->>'pos_x', '')::numeric, nullif(v_spot->>'pos_y', '')::numeric,
              nullif(v_spot->>'width', '')::numeric, nullif(v_spot->>'height', '')::numeric,
              nullif(trim(coalesce(v_spot->>'size_tag', '')), ''), v_item, v_variant)
      returning "Id" into v_spot_id;
    end if;
    v_keep := v_keep || v_spot_id;
  end loop;

  delete from public."ProductionShelfSpots" where "ShelfId" = v_id and "Id" <> all(v_keep);
  return v_id;
end;
$$;

grant execute on function public.admin_save_production_shelf(text, text, int, text, text, jsonb, text) to anon;

notify pgrst, 'reload schema';
