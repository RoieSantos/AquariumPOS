-- Production Shelf Map: COUNT FROM per rack - per "in the item per shelf i want to be able to control if
-- we will check on the serials or in the item ledger entry. by default its serials".
--
-- Each spot linked to an item gets CountSource:
--   'serials' (default) - IN_STOCK serials of the item at the shelf's location (as before).
--   'ledger'            - the item's on-hand at the location from the Item Ledger (sum of ItemLedgerEntries),
--                         for items that aren't serial-tracked or whose serials aren't kept up to date.
-- Set in Edit Layout > rack > "Count from". Auto Order uses the same count per rack.
--
--   ProductionShelfSpots.CountSource
--   staff_get_production_shelves / admin_save_production_shelf  - re-created with count_source
--                                                                  (otherwise same as supabase_production_shelf_size_tags.sql)
--   staff_list_production_location_ledger_qty(warehouse)          - on-hand per item / variant at a location for the
--                                                                  items linked to 'ledger' racks there.
--
-- Run AFTER supabase_production_shelf_size_tags.sql. Safe to re-run.

alter table public."ProductionShelfSpots" add column if not exists "CountSource" varchar(10) not null default 'serials';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'CK_ProductionShelfSpots_CountSource') then
    alter table public."ProductionShelfSpots"
      add constraint "CK_ProductionShelfSpots_CountSource" check ("CountSource" in ('serials', 'ledger'));
  end if;
end;
$$;

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
  v_count_source text;
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
    v_count_source := case when lower(coalesce(v_spot->>'count_source', '')) = 'ledger' then 'ledger' else 'serials' end;
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
            "VariantId" = v_variant,
            "CountSource" = v_count_source
        where "Id" = v_spot_id;
    else
      insert into public."ProductionShelfSpots" ("ShelfId", "RowNo", "ColNo", "Label", "Capacity", "Notes", "PosX", "PosY", "Width", "Height",
                                                 "SizeTag", "ItemCode", "VariantId", "CountSource")
      values (v_id, (v_spot->>'row_no')::int, (v_spot->>'col_no')::int, coalesce(trim(v_spot->>'label'), ''),
              nullif(v_spot->>'capacity', '')::int, nullif(trim(coalesce(v_spot->>'notes', '')), ''),
              nullif(v_spot->>'pos_x', '')::numeric, nullif(v_spot->>'pos_y', '')::numeric,
              nullif(v_spot->>'width', '')::numeric, nullif(v_spot->>'height', '')::numeric,
              nullif(trim(coalesce(v_spot->>'size_tag', '')), ''), v_item, v_variant, v_count_source)
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
-- On-hand from the Item Ledger for the items linked to 'ledger' racks at a location
-- ============================================================================
-- Same shape as staff_list_production_location_serials' matching fields (item_code, variant_code,
-- variant_name, main_item_code) plus qty, so the page can count / split it by colour the same way. A
-- ledger row with no variant (an item with a single variant) is given that variant's id, which is what
-- serials and rack links carry.

drop function if exists public.staff_list_production_location_ledger_qty(text, text, text);

create or replace function public.staff_list_production_location_ledger_qty(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text
)
returns table(item_code text, item_description text, variant_code text, variant_name text, main_item_code text, qty numeric)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with linked as (
      select distinct sp."ItemCode" as item_code
      from public."ProductionShelfSpots" sp
      join public."ProductionShelves" sh on sh."Id" = sp."ShelfId"
      where sh."WarehouseId" = p_warehouse_id
        and sp."CountSource" = 'ledger'
        and sp."ItemCode" is not null
    ),
    balances as (
      select e."ItemCode" as item_code,
             coalesce(e."VariantId",
               (select min(v1."VariationId") from public."Variants" v1 where v1."ItemCode" = e."ItemCode" having count(*) = 1)) as variant_code,
             sum(e."Quantity") as qty
      from public."ItemLedgerEntries" e
      where e."WarehouseId" = p_warehouse_id
      group by e."ItemCode", e."VariantId"
    )
    select b.item_code::text, i."Name"::text, b.variant_code::text,
           coalesce(nullif(trim(v."VariantName"), ''), v."SKU")::text,
           nullif(trim(v."MainItemCode"), '')::text,
           b.qty
    from balances b
    left join public."Variants" v on v."VariationId" = b.variant_code
    left join public."Items" i on i."Code" = b.item_code
    where b.qty > 0
      and exists (select 1 from linked l where l.item_code = b.item_code or l.item_code = nullif(trim(v."MainItemCode"), ''))
    order by b.item_code, b.variant_code;
end;
$$;

grant execute on function public.staff_list_production_location_ledger_qty(text, text, text) to anon;

notify pgrst, 'reload schema';
