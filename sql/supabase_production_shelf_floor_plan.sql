-- Production Shelf Map: FLOOR PLAN layout - per "create a new shelf look like this" (a sketch of the
-- production floor: two pairs of upright racks on the left, four long racks on the right, three
-- along the bottom - different sizes and orientations, not rows of equal boxes).
--
-- A shelf is now either:
--   'grid'  - rows of spots (as before), or
--   'floor' - each spot drawn at its own position and size (PosX/PosY/Width/Height, in plan units;
--             the page scales the plan to the screen). Spots are dragged / resized on the page.
-- Everything else (serials on spots, Unplaced, Find) works the same for both.
--
-- Also creates the shelf from the sketch ("Production Floor", 11 spots A1-A4 / B1-B4 / C1-C3) at the
-- first production warehouse - rename it, move it to another warehouse or relabel spots on the page.
--
-- Run AFTER supabase_production_shelf_map.sql. Safe to re-run (the sketch shelf is only created once).

alter table public."ProductionShelves" add column if not exists "Layout" varchar(10) not null default 'grid';
alter table public."ProductionShelves" drop constraint if exists "CK_ProductionShelves_Layout";
alter table public."ProductionShelves" add constraint "CK_ProductionShelves_Layout" check ("Layout" in ('grid', 'floor'));

alter table public."ProductionShelfSpots" add column if not exists "PosX" numeric(10, 2);
alter table public."ProductionShelfSpots" add column if not exists "PosY" numeric(10, 2);
alter table public."ProductionShelfSpots" add column if not exists "Width" numeric(10, 2);
alter table public."ProductionShelfSpots" add column if not exists "Height" numeric(10, 2);

-- ============================================================================
-- Reading - same as supabase_production_shelf_map.sql plus layout + spot position/size
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
-- Saving - adds p_layout and each spot's pos_x / pos_y / width / height
-- ============================================================================

drop function if exists public.admin_save_production_shelf(text, text, int, text, text, jsonb);
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
    if v_spot_id is not null and exists (select 1 from public."ProductionShelfSpots" where "Id" = v_spot_id and "ShelfId" = v_id) then
      update public."ProductionShelfSpots"
        set "RowNo" = (v_spot->>'row_no')::int, "ColNo" = (v_spot->>'col_no')::int,
            "Label" = coalesce(trim(v_spot->>'label'), ''),
            "Capacity" = nullif(v_spot->>'capacity', '')::int,
            "Notes" = nullif(trim(coalesce(v_spot->>'notes', '')), ''),
            "PosX" = nullif(v_spot->>'pos_x', '')::numeric,
            "PosY" = nullif(v_spot->>'pos_y', '')::numeric,
            "Width" = nullif(v_spot->>'width', '')::numeric,
            "Height" = nullif(v_spot->>'height', '')::numeric
        where "Id" = v_spot_id;
    else
      insert into public."ProductionShelfSpots" ("ShelfId", "RowNo", "ColNo", "Label", "Capacity", "Notes", "PosX", "PosY", "Width", "Height")
      values (v_id, (v_spot->>'row_no')::int, (v_spot->>'col_no')::int, coalesce(trim(v_spot->>'label'), ''),
              nullif(v_spot->>'capacity', '')::int, nullif(trim(coalesce(v_spot->>'notes', '')), ''),
              nullif(v_spot->>'pos_x', '')::numeric, nullif(v_spot->>'pos_y', '')::numeric,
              nullif(v_spot->>'width', '')::numeric, nullif(v_spot->>'height', '')::numeric)
      returning "Id" into v_spot_id;
    end if;
    v_keep := v_keep || v_spot_id;
  end loop;

  delete from public."ProductionShelfSpots" where "ShelfId" = v_id and "Id" <> all(v_keep);
  return v_id;
end;
$$;

grant execute on function public.admin_save_production_shelf(text, text, int, text, text, jsonb, text) to anon;

-- ============================================================================
-- The shelf from the sketch
-- ============================================================================
-- Positions are the sketch's own coordinates (about 820 x 800 units):
--   A1-A4  upright racks, top-left (two side-by-side pairs)
--   B1-B4  long racks down the right-hand side
--   C1-C3  long racks along the bottom
do $$
declare
  v_warehouse text;
  v_id int;
begin
  if exists (select 1 from public."ProductionShelves" where "Name" = 'Production Floor') then
    return;
  end if;

  select "ID" into v_warehouse from public."Warehouses"
    where "IsProductionWarehouse" and coalesce("IsActive", true)
    order by "Name" limit 1;
  if v_warehouse is null then
    raise notice 'No production warehouse found - Production Floor shelf not created. Tick "Production" on a warehouse in Warehouse Setup and re-run.';
    return;
  end if;

  insert into public."ProductionShelves" ("Name", "WarehouseId", "SortOrder", "Layout")
  values ('Production Floor', v_warehouse, coalesce((select max("SortOrder") + 1 from public."ProductionShelves"), 0), 'floor')
  returning "Id" into v_id;

  insert into public."ProductionShelfSpots" ("ShelfId", "RowNo", "ColNo", "Label", "PosX", "PosY", "Width", "Height") values
    (v_id, 0, 0,  'A1',  28,  24,  50, 161),
    (v_id, 0, 1,  'A2',  90,  20,  48, 160),
    (v_id, 0, 2,  'A3',  23, 215,  57, 170),
    (v_id, 0, 3,  'A4',  97, 213,  51, 163),
    (v_id, 0, 4,  'B1', 577,  94, 200,  48),
    (v_id, 0, 5,  'B2', 573, 170, 191,  57),
    (v_id, 0, 6,  'B3', 569, 263, 216,  69),
    (v_id, 0, 7,  'B4', 564, 348, 224,  70),
    (v_id, 0, 8,  'C1',  18, 719, 145,  55),
    (v_id, 0, 9,  'C2', 185, 711, 122,  60),
    (v_id, 0, 10, 'C3', 328, 706, 125,  67);
end;
$$;

notify pgrst, 'reload schema';
