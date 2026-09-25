-- Shelf Map: a drawn layout of a physical shelf (rows of cells), each cell optionally linked to an
-- Item, showing that item's actual on-hand quantity at the shelf's warehouse (Item Ledger) next to
-- the quantity written on the original drawing.
--
-- Stock is NEVER stored here - on-hand is always read live from ItemLedgerEntries, so the map can't
-- drift from the ledger. DrawnQty is just the count that was written on the paper drawing.
--
-- Viewing + counting: any authorized staff (staff_get_shelf_maps, staff_set_shelf_cell_count).
-- Editing the layout: Super User or Store Manager (admin_*).
-- Run in the Supabase SQL Editor (needs supabase_item_ledger_entries.sql already applied).

create table if not exists public."ShelfMaps" (
  "Id" serial primary key,
  "Name" varchar(200) not null,
  "WarehouseId" varchar(100),
  "SortOrder" int not null default 0
);

create table if not exists public."ShelfMapCells" (
  "Id" serial primary key,
  "ShelfId" int not null references public."ShelfMaps"("Id") on delete cascade,
  "RowNo" int not null,
  "ColNo" int not null,
  "Label" varchar(300) not null default '',
  "ModelCode" varchar(100),
  "ItemCode" varchar(200),
  "DrawnQty" numeric(18, 4),
  "Notes" varchar(500)
);

-- "Current count" = what is physically on this shelf spot right now (staff update it from the
-- page, no layout editing needed). Separate from DrawnQty (the paper sketch) and from the ledger.
alter table public."ShelfMapCells" add column if not exists "CurrentQty" numeric(18, 4);
alter table public."ShelfMapCells" add column if not exists "CountedAtUtc" timestamptz;
alter table public."ShelfMapCells" add column if not exists "CountedBy" varchar(100);

create index if not exists "IX_ShelfMapCells_ShelfId" on public."ShelfMapCells" ("ShelfId");

alter table public."ShelfMaps" enable row level security;
alter table public."ShelfMapCells" enable row level security;

-- Layout editors = Super User OR Store Manager, re-verified per call (same trust model as
-- is_admin_authorized, deliberately NOT widening that one - see is_phys_journal_authorized in
-- supabase_phys_journal_store_manager_access.sql). Not granted to anon; only called from inside the
-- security definer functions below.
create or replace function public.is_shelf_map_editor_authorized(p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_super_user boolean;
  v_store_manager boolean;
begin
  select "PasswordHash", "IsActive", "SuperUser", "StoreManager"
    into v_password_hash, v_is_active, v_super_user, v_store_manager
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active or not (coalesce(v_super_user, false) or coalesce(v_store_manager, false)) then
    return false;
  end if;

  return v_password_hash = crypt(p_password, v_password_hash);
end;
$$;

drop function if exists public.staff_get_shelf_maps(text, text);

create or replace function public.staff_get_shelf_maps(p_admin_username text, p_admin_password text)
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
    select jsonb_agg(
      jsonb_build_object(
        'id', s."Id",
        'name', s."Name",
        'warehouse_id', s."WarehouseId",
        'warehouse_name', w."Name",
        'cells', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', c."Id",
              'row_no', c."RowNo",
              'col_no', c."ColNo",
              'label', c."Label",
              'model_code', c."ModelCode",
              'item_code', c."ItemCode",
              'item_name', i."Name",
              'drawn_qty', c."DrawnQty",
              'notes', c."Notes",
              'current_qty', c."CurrentQty",
              'counted_at', c."CountedAtUtc",
              'counted_by', c."CountedBy",
              -- Everything counted on ANY shelf of this same location for this item - the figure
              -- to reconcile against the ledger when an item sits on more than one shelf spot.
              'shelf_total', case when c."ItemCode" is null then null else
                (select sum(x."CurrentQty") from public."ShelfMapCells" x
                 join public."ShelfMaps" sx on sx."Id" = x."ShelfId"
                 where x."ItemCode" = c."ItemCode" and sx."WarehouseId" is not distinct from s."WarehouseId") end,
              -- Live ledger balance at the shelf's warehouse, all variants combined. Null when the
              -- cell has no item or the shelf has no warehouse yet (nothing to look up).
              'on_hand', case when c."ItemCode" is null or s."WarehouseId" is null then null else
                coalesce((select sum(e."Quantity") from public."ItemLedgerEntries" e
                          where e."ItemCode" = c."ItemCode" and e."WarehouseId" = s."WarehouseId"), 0) end,
              -- Same item drawn in more than one cell of this shelf -> on_hand is the item's total,
              -- not per cell; the page flags it instead of pretending it's split.
              'item_cells', case when c."ItemCode" is null then 0 else
                (select count(*) from public."ShelfMapCells" x where x."ShelfId" = s."Id" and x."ItemCode" = c."ItemCode") end
            ) order by c."RowNo", c."ColNo"
          ) from public."ShelfMapCells" c
          left join public."Items" i on i."Code" = c."ItemCode"
          where c."ShelfId" = s."Id"
        ), '[]'::jsonb)
      ) order by s."SortOrder", s."Id"
    )
    from public."ShelfMaps" s
    left join public."Warehouses" w on w."ID" = s."WarehouseId"
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.staff_get_shelf_maps(text, text) to anon;

drop function if exists public.admin_save_shelf_map(text, text, int, text, text, jsonb);

-- p_id null = create. p_cells: [{row_no, col_no, label, model_code, item_code, drawn_qty, notes}].
-- Cells are replaced wholesale (delete + insert) - the shelf is small and edited as one drawing.
create or replace function public.admin_save_shelf_map(
  p_admin_username text,
  p_admin_password text,
  p_id int,
  p_name text,
  p_warehouse_id text,
  p_cells jsonb
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_id int := p_id;
begin
  if not public.is_shelf_map_editor_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'Shelf name is required.';
  end if;

  if v_id is null then
    insert into public."ShelfMaps" ("Name", "WarehouseId", "SortOrder")
    values (trim(p_name), nullif(trim(coalesce(p_warehouse_id, '')), ''),
            coalesce((select max("SortOrder") + 1 from public."ShelfMaps"), 0))
    returning "Id" into v_id;
  else
    update public."ShelfMaps"
       set "Name" = trim(p_name), "WarehouseId" = nullif(trim(coalesce(p_warehouse_id, '')), '')
     where "Id" = v_id;
    if not found then raise exception 'Shelf not found.'; end if;
    delete from public."ShelfMapCells" where "ShelfId" = v_id;
  end if;

  insert into public."ShelfMapCells" ("ShelfId", "RowNo", "ColNo", "Label", "ModelCode", "ItemCode", "DrawnQty", "Notes",
                                      "CurrentQty", "CountedAtUtc", "CountedBy")
  select v_id, (c->>'row_no')::int, (c->>'col_no')::int, coalesce(c->>'label', ''),
         nullif(trim(coalesce(c->>'model_code', '')), ''),
         nullif(trim(coalesce(c->>'item_code', '')), ''),
         nullif(c->>'drawn_qty', '')::numeric,
         nullif(trim(coalesce(c->>'notes', '')), ''),
         nullif(c->>'current_qty', '')::numeric,
         nullif(c->>'counted_at', '')::timestamptz,
         nullif(c->>'counted_by', '')
  from jsonb_array_elements(coalesce(p_cells, '[]'::jsonb)) c;

  return v_id;
end;
$$;

grant execute on function public.admin_save_shelf_map(text, text, int, text, text, jsonb) to anon;

drop function if exists public.admin_delete_shelf_map(text, text, int);

create or replace function public.admin_delete_shelf_map(p_admin_username text, p_admin_password text, p_id int)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_shelf_map_editor_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  delete from public."ShelfMaps" where "Id" = p_id;
end;
$$;

grant execute on function public.admin_delete_shelf_map(text, text, int) to anon;

-- ============================================================================
-- Seed: first drawing ("Pumps & Filters" shelf), transcribed from the photo of the paper sketch.
-- Only runs when no shelf has been created yet. Items are NOT linked yet and the shelf has no
-- warehouse - pick the warehouse and use "Auto-link items" on the Shelf Map page.
-- ============================================================================
do $$
declare
  v_id int;
begin
  if exists (select 1 from public."ShelfMaps") then return; end if;

  insert into public."ShelfMaps" ("Name", "SortOrder") values ('Shelf 1 - Pumps & Filters', 0) returning "Id" into v_id;

  insert into public."ShelfMapCells" ("ShelfId", "RowNo", "ColNo", "Label", "ModelCode", "DrawnQty") values
    (v_id, 0, 0, 'Showa Filter Wool', null, 30),
    (v_id, 0, 1, 'Infinity Wool', null, 30),

    (v_id, 1, 0, 'Poseidon', 'RS-1781F', 6),
    (v_id, 1, 1, 'Poseidon', 'RS-2780F', 6),
    (v_id, 1, 2, 'Poseidon', 'RS-3780F', 6),

    (v_id, 2, 0, 'Aqua Venus Hang-on', 'LW', 5),
    (v_id, 2, 1, 'OF Ultra Slim Hang-on', 'US-03', 5),
    (v_id, 2, 2, 'Aqua Speed Internal Filter', 'A300-3F', 5),
    (v_id, 2, 3, 'Infinity Hang-on Filter', 'CS-48', 10),
    (v_id, 2, 4, 'Infinity Hang-on', 'CS-35', 10),
    (v_id, 2, 5, 'Infinity Hang-on', 'CS-25', 10),
    (v_id, 2, 6, 'Aqua Speed Aqua Pump', 'A3000', 10),
    (v_id, 2, 7, 'Aqua Speed Aqua Pump', 'A2000', 10),
    (v_id, 2, 8, 'Sea Billion Aqua Pump', 'HY-304', 10),

    (v_id, 3, 0, 'Quantong Wave Maker 25W', null, 5),
    (v_id, 3, 1, 'Sunsun Wave Maker 220-240', null, 5),
    (v_id, 3, 2, 'Winner Aeolus Air Pump', null, 10),
    (v_id, 3, 3, 'Atec Air Pump', 'AR-8500', 10),
    (v_id, 3, 4, 'Atec Air Pump', 'AR-7500', 10),
    (v_id, 3, 5, 'Atec Air Pump', 'AR-2500', 16),
    (v_id, 3, 6, 'Aqua Speed Air Pump', 'AP-556', 10),
    (v_id, 3, 7, 'Aqua Speed Air Pump', 'AP-226', 16),
    (v_id, 3, 8, 'Aqua Speed Aqua Pump', '1100A', 12),

    (v_id, 4, 0, 'Outlet EQ / Defective Items', null, null),
    (v_id, 4, 1, 'Resun Magnetic Air Pump', 'AC0-004', 3),
    (v_id, 4, 2, 'Bio Foam Filter', 'BF-1', 3),
    (v_id, 4, 3, 'Bio-Sponge Filter', '2813', 5),
    (v_id, 4, 4, 'Bio-Sponge Filter', '2812', 10),
    (v_id, 4, 5, 'Bio-Sponge Filter', '2810', 16),
    (v_id, 4, 6, 'Infinity Bio Sponge Filter', '2835', 16),
    (v_id, 4, 7, 'Infinity Bio Sponge Filter', '2833', 20);
end;
$$;

drop function if exists public.staff_set_shelf_cell_count(text, text, int, numeric);

-- Any authorized staff can update a spot's current count (it is a count, not a layout change).
-- p_qty null clears it.
create or replace function public.staff_set_shelf_cell_count(
  p_admin_username text,
  p_admin_password text,
  p_cell_id int,
  p_qty numeric
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
  if p_qty is not null and p_qty < 0 then
    raise exception 'Count cannot be negative.';
  end if;
  update public."ShelfMapCells"
     set "CurrentQty" = p_qty, "CountedAtUtc" = now(), "CountedBy" = p_admin_username
   where "Id" = p_cell_id;
  if not found then raise exception 'Shelf spot not found.'; end if;
end;
$$;

grant execute on function public.staff_set_shelf_cell_count(text, text, int, numeric) to anon;

-- One-time starting point: the counts written on the paper drawing become each spot's current
-- count, so the page isn't blank. Only fills spots never counted; safe to re-run.
update public."ShelfMapCells"
   set "CurrentQty" = "DrawnQty"
 where "CurrentQty" is null and "CountedAtUtc" is null and "DrawnQty" is not null;

notify pgrst, 'reload schema';
