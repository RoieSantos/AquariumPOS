-- One-off: "Filter Medias" shelf for Amaya with 5 spots, per direct request ("in the shelf map can you
-- create me a new one for Amaya - Filter Medias" / "add 5 spots for the filter medias shelf").
--
-- No sketch/contents were given, so the 5 spots are placeholders in one row, labelled "Spot 1".."Spot 5",
-- not linked to any item. Open it on the Shelf Map page (Location: Amaya, Shelf: Filter Medias) and use
-- Edit Layout to rename each spot and link it to its item.
--
-- Safe whether or not the earlier empty-shelf version of this script was already run: creates the shelf
-- only if it's missing, and adds the 5 spots only while the shelf has no cells yet (never duplicates or
-- overwrites a layout already edited on the page). Stops with a message if it can't find exactly one
-- warehouse whose name starts with "Amaya".
--
-- Needs supabase_shelf_maps.sql already applied. Same conventions as
-- supabase_shelf_map_fish_food_accessories_amaya.sql.

do $$
declare
  v_name constant text := 'Filter Medias';
  v_location_prefix constant text := 'Amaya';
  v_spots constant int := 5;
  v_warehouse_id text;
  v_count int;
  v_shelf_id int;
begin
  select count(*), min(w."ID") into v_count, v_warehouse_id
    from public."Warehouses" w
   where w."Name" ilike v_location_prefix || '%';

  if v_count <> 1 then
    raise exception 'Expected exactly one warehouse starting with "%", found % - set v_location_prefix.', v_location_prefix, v_count;
  end if;

  select "Id" into v_shelf_id
    from public."ShelfMaps"
   where "Name" = v_name and "WarehouseId" = v_warehouse_id;

  if v_shelf_id is null then
    insert into public."ShelfMaps" ("Name", "WarehouseId", "SortOrder")
    values (v_name, v_warehouse_id, coalesce((select max("SortOrder") + 1 from public."ShelfMaps"), 0))
    returning "Id" into v_shelf_id;
    raise notice 'Created shelf "%" (Id %) for warehouse %.', v_name, v_shelf_id, v_warehouse_id;
  end if;

  if exists (select 1 from public."ShelfMapCells" where "ShelfId" = v_shelf_id) then
    raise notice 'Shelf "%" (Id %) already has cells - left as is.', v_name, v_shelf_id;
    return;
  end if;

  -- One row (RowNo 0), spots left to right (ColNo 0..4).
  insert into public."ShelfMapCells" ("ShelfId", "RowNo", "ColNo", "Label")
  select v_shelf_id, 0, n - 1, 'Spot ' || n
  from generate_series(1, v_spots) as n;

  raise notice 'Added % spots to shelf "%" (Id %).', v_spots, v_name, v_shelf_id;
end;
$$;

select s."Id", s."Name", w."Name" as warehouse, c."RowNo", c."ColNo", c."Label"
from public."ShelfMaps" s
left join public."Warehouses" w on w."ID" = s."WarehouseId"
left join public."ShelfMapCells" c on c."ShelfId" = s."Id"
where s."Name" = 'Filter Medias'
order by c."RowNo", c."ColNo";
