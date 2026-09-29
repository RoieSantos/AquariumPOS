-- Production Shelf Map - per "under production order module i want to create a shelf map for
-- aquarium / sump / stands, this time it's linked to the serials".
--
-- Same drawn layout as the Shelf Map (supabase_shelf_maps.sql) - a shelf/rack at a warehouse, made of
-- rows of spots - but a spot doesn't hold a typed count: it holds the actual SERIALS stored there
-- (ItemSerialTracking). So the map answers "where is RS-AQ-2412-26-000014?" and "what's on rack A?".
--
--   * A serial is shown on a spot only while it is still IN_STOCK at that shelf's warehouse
--     (ItemSerialTracking."Location" = the warehouse name). Once it is sold, transferred away or
--     reversed it simply drops off the map - no clean-up needed, and a serial transferred back later
--     shows up as Unplaced again rather than on a stale spot.
--   * UNPLACED = IN_STOCK serials at the warehouse that aren't on any of its spots (e.g. just output
--     by a Production Order). The page lists them so they can be put away.
--   * Placing a serial on another spot moves it (one spot per serial).
--   * ItemSerialTracking itself is not changed - placement lives in its own table.
--
-- Who: layout (shelves/spots) - Super User or Production Manager. Putting serials away / moving them -
-- any active staff (same as Shelf Map counts).
--
-- Run AFTER supabase_production_orders.sql (it also re-creates staff_list_production_order_serials
-- to add the spot). Safe to re-run.

create table if not exists public."ProductionShelves" (
    "Id" serial primary key,
    "Name" varchar(200) not null,
    "WarehouseId" varchar(100) not null,
    "SortOrder" int not null default 0
);

create table if not exists public."ProductionShelfSpots" (
    "Id" serial primary key,
    "ShelfId" int not null references public."ProductionShelves" ("Id") on delete cascade,
    "RowNo" int not null,
    "ColNo" int not null,
    "Label" varchar(200) not null default '',
    -- How many units fit - only used to show a spot as full.
    "Capacity" int check ("Capacity" is null or "Capacity" > 0),
    "Notes" varchar(500)
);

create index if not exists "IX_ProductionShelfSpots_Shelf" on public."ProductionShelfSpots" ("ShelfId");

-- One row per placed serial. Deleting a spot (or its shelf) puts its serials back to Unplaced.
create table if not exists public."ProductionShelfSerials" (
    "RunningSerialNo" bigint primary key references public."ItemSerialTracking" ("RunningSerialNo") on delete cascade,
    "SpotId" int not null references public."ProductionShelfSpots" ("Id") on delete cascade,
    "PlacedAtUtc" timestamptz not null default now(),
    "PlacedBy" varchar(100)
);

create index if not exists "IX_ProductionShelfSerials_Spot" on public."ProductionShelfSerials" ("SpotId");

alter table public."ProductionShelves" enable row level security;
alter table public."ProductionShelfSpots" enable row level security;
alter table public."ProductionShelfSerials" enable row level security;
revoke all on public."ProductionShelves", public."ProductionShelfSpots", public."ProductionShelfSerials" from anon, authenticated;

-- ============================================================================
-- Reading
-- ============================================================================

-- Placements that are still true: the serial is IN_STOCK at the spot's shelf's warehouse.
create or replace view public."_ProductionShelfPlacements" as
  select ps."RunningSerialNo", ps."SpotId", ps."PlacedAtUtc", ps."PlacedBy", sp."ShelfId", sh."WarehouseId"
  from public."ProductionShelfSerials" ps
  join public."ProductionShelfSpots" sp on sp."Id" = ps."SpotId"
  join public."ProductionShelves" sh on sh."Id" = sp."ShelfId"
  join public."Warehouses" w on w."ID" = sh."WarehouseId"
  join public."ItemSerialTracking" s on s."RunningSerialNo" = ps."RunningSerialNo"
  where s."Status" = 'IN_STOCK' and coalesce(s."Location", '') = coalesce(w."Name", '');

revoke all on public."_ProductionShelfPlacements" from anon, authenticated;

drop function if exists public.staff_get_production_shelves(text, text);

-- Every shelf with its spots and the serials on each spot.
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

drop function if exists public.staff_list_unplaced_production_serials(text, text, text, text);

-- IN_STOCK serials at the warehouse that are on none of its spots.
create or replace function public.staff_list_unplaced_production_serials(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
  p_search text default null
)
returns table(running_serial_no bigint, serial_no text, item_code text, item_description text,
              variant_code text, variant_name text, source_document_no text, created_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
declare
  v_warehouse_name text;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
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
           s."SourceDocumentNo"::text, s."CreatedAtUtc"
    from public."ItemSerialTracking" s
    left join public."Items" i on i."Code" = s."ItemCode"
    left join public."Variants" v on v."VariationId" = s."VariantCode"
    where s."Status" = 'IN_STOCK'
      and s."Location" = v_warehouse_name
      and not exists (select 1 from public."_ProductionShelfPlacements" p
                      where p."RunningSerialNo" = s."RunningSerialNo" and p."WarehouseId" = p_warehouse_id)
      and (v_search is null
        or s."SerialNo" ilike '%' || v_search || '%'
        or s."ItemCode" ilike '%' || v_search || '%'
        or coalesce(s."ItemDescription", '') ilike '%' || v_search || '%')
    order by s."ItemCode", s."SerialNo"
    limit 500;
end;
$$;

grant execute on function public.staff_list_unplaced_production_serials(text, text, text, text) to anon;

-- ============================================================================
-- Putting away
-- ============================================================================

drop function if exists public.staff_place_production_serial(text, text, int, text);

-- p_serial_no: typed or scanned (trimmed, case-insensitive). Moves it if it's already on another spot.
-- Returns the serial's RunningSerialNo.
create or replace function public.staff_place_production_serial(
  p_admin_username text,
  p_admin_password text,
  p_spot_id int,
  p_serial_no text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_warehouse_name text;
  v_serial public."ItemSerialTracking";
  v_capacity int;
  v_used int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select w."Name", sp."Capacity" into v_warehouse_name, v_capacity
    from public."ProductionShelfSpots" sp
    join public."ProductionShelves" sh on sh."Id" = sp."ShelfId"
    join public."Warehouses" w on w."ID" = sh."WarehouseId"
    where sp."Id" = p_spot_id;
  if not found then
    raise exception 'Shelf spot not found.';
  end if;

  select * into v_serial from public."ItemSerialTracking"
    where upper("SerialNo") = upper(trim(coalesce(p_serial_no, '')));
  if not found then
    raise exception 'Serial "%" not found.', trim(coalesce(p_serial_no, ''));
  end if;
  if v_serial."Status" <> 'IN_STOCK' then
    raise exception 'Serial % is %, not In Stock.', v_serial."SerialNo", v_serial."Status";
  end if;
  if coalesce(v_serial."Location", '') <> v_warehouse_name then
    raise exception 'Serial % is at %, not %. Transfer it here first.', v_serial."SerialNo", coalesce(v_serial."Location", '(no location)'), v_warehouse_name;
  end if;

  if v_capacity is not null then
    select count(*) into v_used from public."_ProductionShelfPlacements"
      where "SpotId" = p_spot_id and "RunningSerialNo" <> v_serial."RunningSerialNo";
    if v_used >= v_capacity then
      raise exception 'This spot is full (% of %).', v_used, v_capacity;
    end if;
  end if;

  insert into public."ProductionShelfSerials" ("RunningSerialNo", "SpotId", "PlacedBy")
  values (v_serial."RunningSerialNo", p_spot_id, p_admin_username)
  on conflict ("RunningSerialNo") do update
    set "SpotId" = excluded."SpotId", "PlacedAtUtc" = now(), "PlacedBy" = excluded."PlacedBy";

  return v_serial."RunningSerialNo";
end;
$$;

grant execute on function public.staff_place_production_serial(text, text, int, text) to anon;

drop function if exists public.staff_unplace_production_serial(text, text, bigint);

create or replace function public.staff_unplace_production_serial(
  p_admin_username text,
  p_admin_password text,
  p_running_serial_no bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  delete from public."ProductionShelfSerials" where "RunningSerialNo" = p_running_serial_no;
end;
$$;

grant execute on function public.staff_unplace_production_serial(text, text, bigint) to anon;

-- ============================================================================
-- Layout (Super User / Production Manager)
-- ============================================================================

drop function if exists public.admin_save_production_shelf(text, text, int, text, text, jsonb);

-- p_spots: [{id or null, row_no, col_no, label, capacity, notes}]. Spots keep their id so serials
-- placed on them stay put; a spot left out is deleted and its serials go back to Unplaced.
create or replace function public.admin_save_production_shelf(
  p_admin_username text,
  p_admin_password text,
  p_id int,
  p_name text,
  p_warehouse_id text,
  p_spots jsonb
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id int := p_id;
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
    insert into public."ProductionShelves" ("Name", "WarehouseId", "SortOrder")
    values (trim(p_name), p_warehouse_id, coalesce((select max("SortOrder") + 1 from public."ProductionShelves"), 0))
    returning "Id" into v_id;
  else
    -- Moving the shelf to another warehouse would leave every placement pointing at stock that isn't there.
    if exists (select 1 from public."ProductionShelves" where "Id" = v_id and "WarehouseId" <> p_warehouse_id)
       and exists (select 1 from public."_ProductionShelfPlacements" where "ShelfId" = v_id) then
      raise exception 'This shelf has serials on it - take them off before moving it to another warehouse.';
    end if;
    update public."ProductionShelves" set "Name" = trim(p_name), "WarehouseId" = p_warehouse_id where "Id" = v_id;
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
            "Notes" = nullif(trim(coalesce(v_spot->>'notes', '')), '')
        where "Id" = v_spot_id;
    else
      insert into public."ProductionShelfSpots" ("ShelfId", "RowNo", "ColNo", "Label", "Capacity", "Notes")
      values (v_id, (v_spot->>'row_no')::int, (v_spot->>'col_no')::int, coalesce(trim(v_spot->>'label'), ''),
              nullif(v_spot->>'capacity', '')::int, nullif(trim(coalesce(v_spot->>'notes', '')), ''))
      returning "Id" into v_spot_id;
    end if;
    v_keep := v_keep || v_spot_id;
  end loop;

  delete from public."ProductionShelfSpots" where "ShelfId" = v_id and "Id" <> all(v_keep);
  return v_id;
end;
$$;

grant execute on function public.admin_save_production_shelf(text, text, int, text, text, jsonb) to anon;

drop function if exists public.admin_delete_production_shelf(text, text, int);

create or replace function public.admin_delete_production_shelf(p_admin_username text, p_admin_password text, p_id int)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can delete production shelves.';
  end if;
  delete from public."ProductionShelves" where "Id" = p_id;
end;
$$;

grant execute on function public.admin_delete_production_shelf(text, text, int) to anon;

-- ============================================================================
-- Production Orders: show where each output serial was put away
-- ============================================================================

drop function if exists public.staff_list_production_order_serials(text, text, text);

create or replace function public.staff_list_production_order_serials(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(serial_no text, item_code text, item_description text, variant_code text, location text, status text,
              entry_no bigint, posted_at timestamptz, shelf_spot text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Production Manager can view output serials.';
  end if;

  return query
    select s."SerialNo"::text, s."ItemCode"::text, s."ItemDescription"::text, s."VariantCode"::text,
           s."Location"::text, s."Status"::text, o."EntryNo", o."PostedAtUtc",
           (select sh."Name" || ' › ' || coalesce(nullif(sp."Label", ''), 'Row ' || (sp."RowNo" + 1) || ' spot ' || (sp."ColNo" + 1))
              from public."_ProductionShelfPlacements" p
              join public."ProductionShelfSpots" sp on sp."Id" = p."SpotId"
              join public."ProductionShelves" sh on sh."Id" = p."ShelfId"
              where p."RunningSerialNo" = s."RunningSerialNo")::text
    from public."ProductionOrderOutputs" o
    join public."ProductionOrderOutputSerials" os on os."EntryNo" = o."EntryNo"
    join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
    where o."ProdOrderNo" = p_no
    order by o."EntryNo", s."SerialNo";
end;
$$;

grant execute on function public.staff_list_production_order_serials(text, text, text) to anon;

notify pgrst, 'reload schema';
