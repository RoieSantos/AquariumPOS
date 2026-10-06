-- One-off: copy the Amaya production shelf map to GMA - "you see the shelf of production shelf for
-- amaya? can you create one exactly the same for GMA".
--
-- Clones every ProductionShelves row at the Amaya warehouse into the GMA warehouse, with all its
-- racks (ProductionShelfSpots: label, row/col, floor-plan position & size, capacity, notes, size tag,
-- linked aquarium/variant, count source) and its Materials strip (ProductionShelfMaterials).
-- Placed serials are NOT copied - GMA counts its own stock.
--
-- Warehouses are matched by name (ILIKE '%amaya%' / '%gma%'); if more than one matches, the
-- production warehouse (and, for Amaya, the one that actually has shelves) wins, otherwise it stops
-- with an error naming the candidates.
--
-- Safe to re-run: a shelf GMA already has with the same name is skipped, not duplicated.
-- Ends with ONE result: the GMA shelves and their rack counts.
-- Run AFTER supabase_production_shelf_count_source.sql and supabase_production_shelf_materials.sql.

do $$
declare
  v_src text;
  v_dst text;
  v_n int;
  v_shelf record;
  v_new_id int;
begin
  -- Amaya: the warehouse whose name has "amaya" and that has production shelves
  select count(distinct w."ID") into v_n
    from public."Warehouses" w join public."ProductionShelves" sh on sh."WarehouseId" = w."ID"
   where w."Name" ilike '%amaya%';
  if v_n = 0 then
    raise exception 'No Amaya warehouse with production shelves found.';
  elsif v_n > 1 then
    raise exception 'More than one Amaya warehouse has production shelves: %',
      (select string_agg(distinct w."Name" || ' (' || w."ID" || ')', ', ')
         from public."Warehouses" w join public."ProductionShelves" sh on sh."WarehouseId" = w."ID"
        where w."Name" ilike '%amaya%');
  end if;
  select distinct w."ID" into v_src
    from public."Warehouses" w join public."ProductionShelves" sh on sh."WarehouseId" = w."ID"
   where w."Name" ilike '%amaya%';

  -- GMA: single match, or the single production one among several
  select count(*) into v_n from public."Warehouses" where "Name" ilike '%gma%' and coalesce("IsActive", true);
  if v_n = 1 then
    select "ID" into v_dst from public."Warehouses" where "Name" ilike '%gma%' and coalesce("IsActive", true);
  else
    select count(*) into v_n from public."Warehouses"
     where "Name" ilike '%gma%' and coalesce("IsActive", true) and "IsProductionWarehouse";
    if v_n <> 1 then
      raise exception 'Could not pick ONE GMA warehouse. Candidates: %',
        coalesce((select string_agg("Name" || ' (' || "ID" || ')', ', ') from public."Warehouses" where "Name" ilike '%gma%'), 'none');
    end if;
    select "ID" into v_dst from public."Warehouses"
     where "Name" ilike '%gma%' and coalesce("IsActive", true) and "IsProductionWarehouse";
  end if;

  for v_shelf in
    select * from public."ProductionShelves" where "WarehouseId" = v_src order by "SortOrder", "Id"
  loop
    if exists (select 1 from public."ProductionShelves" where "WarehouseId" = v_dst and "Name" = v_shelf."Name") then
      raise notice 'GMA already has shelf "%" - skipped.', v_shelf."Name";
      continue;
    end if;

    insert into public."ProductionShelves" ("Name", "WarehouseId", "SortOrder", "Layout")
    values (v_shelf."Name", v_dst, coalesce((select max("SortOrder") + 1 from public."ProductionShelves"), 0), v_shelf."Layout")
    returning "Id" into v_new_id;

    insert into public."ProductionShelfSpots" ("ShelfId", "RowNo", "ColNo", "Label", "Capacity", "Notes",
                                               "PosX", "PosY", "Width", "Height",
                                               "SizeTag", "ItemCode", "VariantId", "CountSource")
    select v_new_id, "RowNo", "ColNo", "Label", "Capacity", "Notes",
           "PosX", "PosY", "Width", "Height",
           "SizeTag", "ItemCode", "VariantId", "CountSource"
      from public."ProductionShelfSpots" where "ShelfId" = v_shelf."Id"
     order by "Id";

    insert into public."ProductionShelfMaterials" ("ShelfId", "ItemCode", "VariantId", "Label", "SortOrder")
    select v_new_id, "ItemCode", "VariantId", "Label", "SortOrder"
      from public."ProductionShelfMaterials" where "ShelfId" = v_shelf."Id"
     order by "SortOrder", "Id";

    raise notice 'Copied shelf "%" to GMA (new id %).', v_shelf."Name", v_new_id;
  end loop;
end;
$$;

select w."Name" as warehouse, sh."Id" as shelf_id, sh."Name" as shelf, sh."Layout" as layout,
       (select count(*) from public."ProductionShelfSpots" sp where sp."ShelfId" = sh."Id") as racks,
       (select count(*) from public."ProductionShelfSpots" sp where sp."ShelfId" = sh."Id" and sp."ItemCode" is not null) as linked_racks,
       (select count(*) from public."ProductionShelfMaterials" m where m."ShelfId" = sh."Id") as materials
  from public."ProductionShelves" sh
  join public."Warehouses" w on w."ID" = sh."WarehouseId"
 where w."Name" ilike '%amaya%' or w."Name" ilike '%gma%'
 order by w."Name", sh."SortOrder", sh."Id";
