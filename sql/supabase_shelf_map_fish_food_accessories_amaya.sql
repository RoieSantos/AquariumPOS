-- One-off: creates the "Fish Food & Accessories" shelf from the second hand-drawn sketch, per direct
-- request ("can you create the shelf for this"). The sketch has no title and no location written on
-- it, so the NAME and LOCATION below are assumptions - change v_name / v_location_prefix first if
-- they're wrong (the location is matched as a name starting with that text, e.g. 'Amaya').
--
-- Needs supabase_shelf_maps.sql already applied. Refuses to run twice (same name + location), and
-- stops with a message if it can't find exactly one matching warehouse.
--
-- Same conventions as supabase_shelf_map_infinity_double_drawer_amaya.sql: the Shelf Map has no
-- merged cells, so each block on the sketch becomes one cell per product, in rows top to bottom /
-- left to right. Label = what's written, ModelCode = size where written, DrawnQty = PCS on the
-- sketch. ItemCode is left blank - link each cell to its item with Edit Layout on the Shelf Map
-- page so the ledger quantity shows. Hard-to-read or missing details are called out in Notes.

do $$
declare
  v_name constant text := 'Fish Food & Accessories';
  v_location_prefix constant text := 'Amaya';
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
    -- Row 0 (top of the left block)
    (0, 1, 'Fresh Water Test Kit', null, 2, null),
    (0, 2, 'Arowana Chips (300g)', '300g', 2, 'Written as "2 cans"'),
    (0, 3, '', null, null, 'Empty box on the sketch'),
    (0, 4, '', null, null, 'Empty box on the sketch'),
    -- Row 1 (Fish Food)
    (1, 1, 'Frymaster 1 (50g)', '50g', 10, 'Fish food - name/size hard to read'),
    (1, 2, 'Frymaster Betta Food', null, 10, null),
    (1, 3, 'Okiko Platinum (100g)', '100g', 5, null),
    (1, 4, 'Hikari Saki Turtle Pellets (200g)', '200g', 3, null),
    (1, 5, 'Sinking Carnivorous Pellets (74g)', '74g', 3, null),
    -- Row 2 (right block, top)
    (2, 1, 'Porpoise Ranchu Food (1kg)', '1kg', 3, 'Size hard to read'),
    (2, 2, 'Porpoise Large Carnivorous (500g)', '500g', 5, null),
    (2, 3, 'Porpoise Large Carnivorous (1kg)', '1kg', 3, null),
    (2, 4, 'Packaging Stocks (Bags sando, Bags ice)', null, null, 'No quantity written'),
    -- Row 3
    (3, 1, 'Porpoise Arowana Food (500g)', '500g', 5, null),
    (3, 2, 'PO1 Packed (100g)', '100g', 50, null),
    (3, 3, 'PO2 Packed (100g)', '100g', 50, 'Same box as PO1 on the sketch'),
    (3, 4, 'PO3 Packed (100g)', '100g', 50, null),
    (3, 5, 'PO1 / PO2 / PO3 Packed (whole sack)', null, null, 'No quantity written'),
    -- Row 4 (bottom right block)
    (4, 1, 'Pool & Accessories (air stones, dimple clip, rubber putty, male/female, elbow & valve)', null, null, 'Several products in one box; some names hard to read'),
    (4, 2, 'KI-Filter Medias', null, null, 'No quantity written'),
    (4, 3, 'Mesh Bag (Large)', null, 20, null),
    -- Row 5
    (5, 1, 'Cleaning Tools (magnet)', null, null, 'No quantity written'),
    (5, 2, 'Mesh Bag (Small)', null, 20, 'Quantity hard to read (20 / 22?)'),
    (5, 3, 'Mesh Bag White / Black (XS)', 'XS', 30, null)
  ) as c(row_no, ord, label, model_code, qty, notes);

  raise notice 'Created shelf "%" (Id %) for warehouse %.', v_name, v_shelf_id, v_warehouse_id;
end;
$$;

select s."Id", s."Name", s."WarehouseId", count(c."Id") as cells
from public."ShelfMaps" s
left join public."ShelfMapCells" c on c."ShelfId" = s."Id"
where s."Name" = 'Fish Food & Accessories'
group by s."Id", s."Name", s."WarehouseId";
