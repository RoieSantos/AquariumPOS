-- One-off: copy the Amaya inventory Shelf Map (shelf-map.html) to GMA - same as
-- supabase_production_shelf_copy_amaya_to_gma.sql did for the Production Shelf Map.
--
-- Clones every ShelfMaps row at the Amaya warehouse into the GMA warehouse, with all its cells
-- (ShelfMapCells: row/col, label, model code, linked item, drawn qty, notes) AND the maintaining
-- count - the big "current count" per cell (CurrentQty), whose per-item total is the shelf qty the
-- Replenish transfer tops GMA back up to. Per "can you put on maintaining count for GMA same as amaya":
-- GMA cells that still have NO count (incl. shelves copied by an earlier run of this file) get
-- Amaya's count for the same shelf name + row/col + item; a count GMA already typed in is never
-- overwritten. CountedBy is set to 'Copied from Amaya' so it's clear where the number came from.
--
-- Warehouses are matched by name (ILIKE '%amaya%' / '%gma%'). Amaya = the one that has shelf maps.
-- If several GMA warehouses match, the one with the same production/store type as the Amaya one
-- wins; otherwise it stops with an error naming the candidates (nothing is copied).
--
-- Safe to re-run: a shelf GMA already has with the same name is not duplicated (only its empty
-- counts are filled). Ends with ONE result: the Amaya and GMA shelf maps, cells and count totals.
-- Run AFTER supabase_shelf_maps.sql.

do $$
declare
  v_src text;
  v_src_is_prod boolean;
  v_dst text;
  v_n int;
  v_shelf record;
  v_new_id int;
begin
  -- Amaya: the warehouse whose name has "amaya" and that has shelf maps
  select count(distinct w."ID") into v_n
    from public."Warehouses" w join public."ShelfMaps" sh on sh."WarehouseId" = w."ID"
   where w."Name" ilike '%amaya%';
  if v_n = 0 then
    raise exception 'No Amaya warehouse with shelf maps found.';
  elsif v_n > 1 then
    raise exception 'More than one Amaya warehouse has shelf maps: %',
      (select string_agg(distinct w."Name" || ' (' || w."ID" || ')', ', ')
         from public."Warehouses" w join public."ShelfMaps" sh on sh."WarehouseId" = w."ID"
        where w."Name" ilike '%amaya%');
  end if;
  select distinct w."ID", coalesce(w."IsProductionWarehouse", false) into v_src, v_src_is_prod
    from public."Warehouses" w join public."ShelfMaps" sh on sh."WarehouseId" = w."ID"
   where w."Name" ilike '%amaya%';

  -- GMA: single match, or the single one of the same type (production / store) as Amaya's
  select count(*) into v_n from public."Warehouses" where "Name" ilike '%gma%' and coalesce("IsActive", true);
  if v_n = 1 then
    select "ID" into v_dst from public."Warehouses" where "Name" ilike '%gma%' and coalesce("IsActive", true);
  else
    select count(*) into v_n from public."Warehouses"
     where "Name" ilike '%gma%' and coalesce("IsActive", true) and coalesce("IsProductionWarehouse", false) = v_src_is_prod;
    if v_n <> 1 then
      raise exception 'Could not pick ONE GMA warehouse. Candidates: %',
        coalesce((select string_agg("Name" || ' (' || "ID" || ')', ', ') from public."Warehouses" where "Name" ilike '%gma%'), 'none');
    end if;
    select "ID" into v_dst from public."Warehouses"
     where "Name" ilike '%gma%' and coalesce("IsActive", true) and coalesce("IsProductionWarehouse", false) = v_src_is_prod;
  end if;

  for v_shelf in
    select * from public."ShelfMaps" where "WarehouseId" = v_src order by "SortOrder", "Id"
  loop
    if exists (select 1 from public."ShelfMaps" where "WarehouseId" = v_dst and "Name" = v_shelf."Name") then
      raise notice 'GMA already has shelf "%" - layout not copied, only empty counts filled.', v_shelf."Name";
      continue;
    end if;

    insert into public."ShelfMaps" ("Name", "WarehouseId", "SortOrder")
    values (v_shelf."Name", v_dst, coalesce((select max("SortOrder") + 1 from public."ShelfMaps"), 0))
    returning "Id" into v_new_id;

    insert into public."ShelfMapCells" ("ShelfId", "RowNo", "ColNo", "Label", "ModelCode", "ItemCode", "DrawnQty", "Notes")
    select v_new_id, "RowNo", "ColNo", "Label", "ModelCode", "ItemCode", "DrawnQty", "Notes"
      from public."ShelfMapCells" where "ShelfId" = v_shelf."Id"
     order by "Id";

    raise notice 'Copied shelf "%" to GMA (new id %).', v_shelf."Name", v_new_id;
  end loop;

  -- Maintaining count: fill every GMA cell that has no count yet from the Amaya cell at the same
  -- shelf name + row/col (same item only, so a GMA cell re-linked to another item is left alone).
  update public."ShelfMapCells" d
     set "CurrentQty" = s."CurrentQty", "CountedAtUtc" = now(), "CountedBy" = 'Copied from Amaya'
    from public."ShelfMaps" dsh, public."ShelfMaps" ssh, public."ShelfMapCells" s
   where dsh."Id" = d."ShelfId" and dsh."WarehouseId" = v_dst
     and ssh."WarehouseId" = v_src and ssh."Name" = dsh."Name"
     and s."ShelfId" = ssh."Id" and s."RowNo" = d."RowNo" and s."ColNo" = d."ColNo"
     and s."ItemCode" is not distinct from d."ItemCode"
     and s."CurrentQty" is not null and d."CurrentQty" is null;
  get diagnostics v_n = row_count;
  raise notice 'Maintaining count copied to % GMA cell(s).', v_n;
end;
$$;

select w."Name" as warehouse, sh."Id" as shelf_id, sh."Name" as shelf,
       (select count(*) from public."ShelfMapCells" c where c."ShelfId" = sh."Id") as cells,
       (select count(*) from public."ShelfMapCells" c where c."ShelfId" = sh."Id" and c."ItemCode" is not null) as linked_cells,
       (select count(*) from public."ShelfMapCells" c where c."ShelfId" = sh."Id" and c."CurrentQty" is not null) as counted_cells,
       (select coalesce(sum(c."CurrentQty"), 0) from public."ShelfMapCells" c where c."ShelfId" = sh."Id") as total_count
  from public."ShelfMaps" sh
  join public."Warehouses" w on w."ID" = sh."WarehouseId"
 where w."Name" ilike '%amaya%' or w."Name" ilike '%gma%'
 order by w."Name", sh."SortOrder", sh."Id";
