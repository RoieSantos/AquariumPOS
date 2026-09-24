-- One-off: creates the "Infinity Plastic Double Drawer Filter Box" shelf for Amaya from the
-- hand-drawn sketch, per direct request ("i want this in new shelf for amaya").
--
-- Needs supabase_shelf_maps.sql already applied. Refuses to run twice (same name + location), and
-- stops with a message if it can't find exactly one warehouse whose name starts with "Amaya".
--
-- HOW THE DRAWING WAS CARRIED OVER
--   * The Shelf Map stores rows of cells with no merged/spanning cells, so each tall block on the
--     sketch (e.g. the Precision Heater column) becomes one cell per line, placed in the row where it
--     sits. Rows follow the sketch top to bottom, cells left to right.
--   * "Label" is what's written in the box, "ModelCode" the model/size where one is written,
--     "DrawnQty" the PCS on the sketch. Nothing here is linked to an Item yet (ItemCode is blank) -
--     link each cell to its item with Edit Layout on the Shelf Map page so the ledger quantity shows.
--   * Cells whose handwriting was hard to read, or had no quantity written, say so in Notes so they
--     can be checked against the paper.

do $$
declare
  v_warehouse_id text;
  v_count int;
  v_shelf_id int;
  v_name constant text := 'Infinity Plastic Double Drawer Filter Box';
begin
  select count(*), min(w."ID") into v_count, v_warehouse_id
    from public."Warehouses" w
   where w."Name" ilike 'amaya%';

  if v_count <> 1 then
    raise exception 'Expected exactly one warehouse named like "Amaya%%", found % - set v_warehouse_id by hand.', v_count;
  end if;

  if exists (select 1 from public."ShelfMaps" where "Name" = v_name and "WarehouseId" = v_warehouse_id) then
    raise exception 'Shelf "%" already exists for this location.', v_name;
  end if;

  insert into public."ShelfMaps" ("Name", "WarehouseId", "SortOrder")
  values (v_name, v_warehouse_id, coalesce((select max("SortOrder") + 1 from public."ShelfMaps"), 0))
  returning "Id" into v_shelf_id;

  insert into public."ShelfMapCells" ("ShelfId", "RowNo", "ColNo", "Label", "ModelCode", "DrawnQty", "Notes")
  select v_shelf_id, c.row_no,
         (row_number() over (partition by c.row_no order by c.ord) - 1)::int,
         c.label, c.model_code, c.qty, c.notes
  from (values
    -- Row 0
    (0,  1, 'Fish Net (4 inch)', null, 5, null),
    (0,  2, 'Precision Heater (100W)', '100W', 3, null),
    (0,  3, 'Aquaspeed Heater (ATH-50B 5W)', 'ATH-50B', 3, null),
    (0,  4, 'Lebaoyu (A30-5W)', 'A30-5W', 5, null),
    (0,  5, 'Hikari Aquarium Lamp (S900-3X)', 'S900-3X', 5, null),
    -- Row 1
    (1,  1, 'Precision Heater (200W)', '200W', 3, null),
    (1,  2, 'Aquaspeed Heater (100W)', '100W', 3, null),
    (1,  3, 'Lebaoyu (A50-7W)', 'A50-7W', 5, null),
    (1,  4, 'Hikari Aquarium Lamp (S1000-3X)', 'S1000-3X', 3, null),
    -- Row 2
    (2,  1, 'Fish Net (5 inch)', null, null, 'No quantity written on the sketch'),
    (2,  2, 'Precision Heater (300W)', '300W', 3, null),
    (2,  3, 'Aquaspeed Heater (200W)', '200W', 3, null),
    (2,  4, 'Lebaoyu (A60-11W)', 'A60-11W', 5, null),
    (2,  5, 'Hikari Aquarium Lamp (S500-3X)', 'S500-3X', 5, null),
    -- Row 3
    (3,  1, 'Lebaoyu (A80-15W)', 'A80-15W', 3, null),
    (3,  2, 'Hikari Aquarium Lamp (S800-3X)', 'S800-3X', 5, null),
    -- Row 4
    (4,  1, 'Fish Net (8 inch)', null, 5, null),
    (4,  2, 'Porpoise Safe Start (1 gal)', null, 3, null),
    (4,  3, 'Porpoise Safe Start (1000ml)', null, 5, null),
    (4,  4, 'Porpoise Safe Start (500ml)', null, 10, null),
    (4,  5, 'Anti Chlorine (1000ml)', null, 5, null),
    (4,  6, 'Anti Chlorine (250ml)', null, 10, 'Size hard to read (250ml / 500ml?)'),
    (4,  7, 'Danios Anti-Ich (110ml)', null, 10, null),
    (4,  8, 'Aqua Gold Meth Blue (250ml)', null, 10, null),
    (4,  9, 'Aqua Gold Meth Blue (120ml)', null, 10, null),
    (4, 10, 'Stress Out (125ml)', null, 10, null),
    (4, 11, 'API Stress Coat (80oz)', null, 5, null),
    (4, 12, 'API Stress Coat (40oz)', null, 5, null),
    (4, 13, 'Talibay Extract (250ml)', null, 10, 'Name hard to read'),
    (4, 14, 'Siphon (medium)', null, 5, null),
    -- Row 5
    (5,  1, 'Fish Net (10 inch)', null, null, 'No quantity written on the sketch'),
    (5,  2, 'Tweezer Mats', null, 2, 'Name hard to read'),
    (5,  3, 'Warm Tone Autofeeder', null, 2, null),
    (5,  4, 'Betta Paradise', null, 2, null),
    (5,  5, 'Sunsun UV (AUB-08A)', 'AUB-08A', 2, null),
    (5,  6, 'X-Series Plus (X2-300)', 'X2-300', 5, null),
    (5,  7, 'M Series Cup Light (MS-5W)', 'MS-5W', 5, null),
    (5,  8, 'Aqua Speed (C240-8W)', 'C240-8W', 5, null),
    (5,  9, 'Aqua Speed (C120-8W)', 'C120-8W', 5, null),
    (5, 10, 'Siphon Cleaner (SC2 10L)', 'SC2 10L', 5, null),
    -- Row 6
    (6,  1, 'Fish Net (12 inch)', null, 5, null),
    (6,  2, 'Sunsun (AUB-10B)', 'AUB-10B', 2, null),
    (6,  3, 'X-Series Plus (X5-100)', 'X5-100', 5, null),
    (6,  4, 'Aqua Speed (C350-12W)', 'C350-12W', 5, null),
    (6,  5, 'Aqua Speed (C160-9W)', 'C160-9W', 5, 'Model hard to read'),
    -- Row 7
    (7,  1, 'X-Series Plus (X7-150)', 'X7-150', 5, null),
    -- Row 8
    (8,  1, 'X-Series Plus (X2-200)', 'X2-200', 5, null),
    -- Row 9
    (9,  1, 'Cosmic Diving Submersible Light (COS-1200m)', 'COS-1200m', 5, null),
    (9,  2, 'Aquaspeed Submersible (T4-400)', 'T4-400', 5, null),
    (9,  3, 'Cosmic Diving Submersible Light (COS-500m)', 'COS-500m', 10, null),
    (9,  4, 'BBS Round Net (Large)', null, 10, null),
    -- Row 10
    (10, 1, 'Cosmic Diving Submersible Light (COS-1000m)', 'COS-1000m', 5, null),
    (10, 2, 'Aquaspeed Submersible (T4-500)', 'T4-500', 5, null),
    (10, 3, 'Cosmic Diving Submersible Light (COS-300m)', 'COS-300m', 10, null),
    (10, 4, 'BBS Round Net (Small)', null, null, 'No quantity written on the sketch'),
    -- Row 11
    (11, 1, 'Cosmic Diving Submersible Light (COS-800m)', 'COS-800m', 5, null),
    (11, 2, 'Aquaspeed Submersible (T4-600)', 'T4-600', 5, null),
    (11, 3, 'Cosmic Diving Submersible Light (COS-200m)', 'COS-200m', 10, null),
    -- Row 12
    (12, 1, 'Cosmic Diving Submersible Light (COS-600m)', 'COS-600m', 5, null),
    -- Row 13: note written under the drawing
    (13, 1, 'For dispatched aquariums - smalls', null, null, 'Note written under the sketch')
  ) as c(row_no, ord, label, model_code, qty, notes);

  raise notice 'Created shelf "%" (Id %) for warehouse %.', v_name, v_shelf_id, v_warehouse_id;
end;
$$;

select s."Id", s."Name", s."WarehouseId", count(c."Id") as cells
from public."ShelfMaps" s
left join public."ShelfMapCells" c on c."ShelfId" = s."Id"
where s."Name" = 'Infinity Plastic Double Drawer Filter Box'
group by s."Id", s."Name", s."WarehouseId";
