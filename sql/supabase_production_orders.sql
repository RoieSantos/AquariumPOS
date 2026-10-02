-- Production Orders - per "i want to create a new module under production: Production orders. this will
-- allow me to build bulk aquariums / sump or stands for restocking".
--
-- A Production Order (PRD-000001) is a restock build: a list of items (aquariums, sumps, stands...)
-- and quantities to make, built at a warehouse, not tied to any customer order. Business Central's
-- Released Production Order, cut down to what this shop does:
--
--   Open      - being drafted. Lines and makers can be edited; makers don't see it yet.
--   Released  - handed to the makers. The Tank Maker / Stand Maker see it on their My Assignments
--               (Online Orders) and mark their part Production Done. The Production Manager posts
--               OUTPUT as units are finished - partial is fine (5 of 10 now, the rest later).
--   Finished  - set automatically once every line is fully output.
--
-- POSTING OUTPUT (staff_post_production_output):
--   * One Item Ledger 'Output' entry per line (BC's own entry type for finished production), at the
--     order's warehouse, document type 'Production Output', all under one TransactionNo.
--   * Serial-tracked items (same rule as Ready to Ship's picker: AQ-, CUSTOM-AQUARIUM, CUSTOM_STAND,
--     CUSTOM-SUMP, CUSTOM_SUMP, or a Categories.IsProductionCategory category) get one new IN_STOCK
--     serial per unit, numbered the desktop's way (RS-<ItemCode>-<YY>-000001), located at the order's
--     warehouse - so Ready to Ship / Transfer Orders can pick them straight away.
--   * Reversing that ledger transaction on Item Ledger Entries gives the quantity back to the line
--     and marks its serials REVERSED - refused if any of those serials was already sold or moved.
--
-- Who: Super User or Production Manager (Staff Role) manage orders and post output. A Tank/Stand
-- Maker only sees Released orders they are assigned to, and can only mark their own part done.
--
-- Run AFTER supabase_item_ledger_entries.sql, supabase_item_ledger_hooks.sql and
-- supabase_production_manager_role.sql. Safe to re-run.

-- ============================================================================
-- 1. Item Ledger: allow the 'Output' entry type
-- ============================================================================

do $$
declare
  v_name text;
begin
  for v_name in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'public."ItemLedgerEntries"'::regclass
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%EntryType%'
  loop
    execute format('alter table public."ItemLedgerEntries" drop constraint %I', v_name);
  end loop;
end;
$$;

alter table public."ItemLedgerEntries"
  add constraint "CK_ItemLedgerEntries_EntryType"
  check ("EntryType" in ('Purchase', 'Sale', 'Positive Adjmt.', 'Negative Adjmt.', 'Transfer', 'Output'));

-- ============================================================================
-- 2. Tables
-- ============================================================================

create sequence if not exists public.production_order_no_seq as bigint;

create table if not exists public."ProductionOrders" (
    "No" varchar(20) primary key,
    "Description" varchar(500),
    "WarehouseId" varchar(100) not null,
    "Status" varchar(20) not null default 'Open' check ("Status" in ('Open', 'Released', 'Finished')),
    "DueDate" date,
    "Notes" varchar(1000),
    "TankMaker" varchar(100),
    "StandMaker" varchar(100),
    "TankDoneAtUtc" timestamptz,
    "StandDoneAtUtc" timestamptz,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now(),
    "ReleasedAtUtc" timestamptz,
    "FinishedAtUtc" timestamptz,
    "UpdatedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_ProductionOrders_Status" on public."ProductionOrders" ("Status");

create table if not exists public."ProductionOrderLines" (
    "LineNo" bigint generated always as identity primary key,
    "ProdOrderNo" varchar(20) not null references public."ProductionOrders" ("No") on delete cascade,
    "ItemCode" varchar(200) not null,
    -- Variants."VariationId" - the same value ItemSerialTracking."VariantCode" and the ledger use.
    "VariantId" varchar(100),
    "Description" varchar(500),
    "Quantity" numeric(18, 4) not null check ("Quantity" > 0),
    "QtyOutput" numeric(18, 4) not null default 0 check ("QtyOutput" >= 0),
    -- Which maker builds it: 'stand' (stands / top covers) or 'tank' (everything else).
    "Part" varchar(10) not null default 'tank' check ("Part" in ('tank', 'stand')),
    check ("QtyOutput" <= "Quantity")
);

create index if not exists "IX_ProductionOrderLines_Order" on public."ProductionOrderLines" ("ProdOrderNo");

-- One row per ledger entry an output posting wrote, and the serials it created - what a reversal
-- needs to hand the quantity back and void the serials.
create table if not exists public."ProductionOrderOutputs" (
    "EntryNo" bigint primary key references public."ItemLedgerEntries" ("EntryNo"),
    "TransactionNo" bigint not null,
    "ProdOrderNo" varchar(20) not null,
    "LineNo" bigint not null,
    "Quantity" numeric(18, 4) not null,
    "PostedBy" varchar(100),
    "PostedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_ProductionOrderOutputs_Order" on public."ProductionOrderOutputs" ("ProdOrderNo");

create table if not exists public."ProductionOrderOutputSerials" (
    "EntryNo" bigint not null references public."ProductionOrderOutputs" ("EntryNo"),
    "RunningSerialNo" bigint not null references public."ItemSerialTracking" ("RunningSerialNo"),
    primary key ("EntryNo", "RunningSerialNo")
);

alter table public."ProductionOrders" enable row level security;
alter table public."ProductionOrderLines" enable row level security;
alter table public."ProductionOrderOutputs" enable row level security;
alter table public."ProductionOrderOutputSerials" enable row level security;
revoke all on public."ProductionOrders", public."ProductionOrderLines",
  public."ProductionOrderOutputs", public."ProductionOrderOutputSerials" from anon, authenticated;

-- ============================================================================
-- 3. Helpers (internal - not granted to anon)
-- ============================================================================

create or replace function public._production_is_manager(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public."StaffUsers"
    where "Username" = p_username and "IsActive"
      and ("SuperUser" or 'ProductionManager' = any(coalesce("StaffRoles", '{}')))
  );
$$;

revoke execute on function public._production_is_manager(text) from public, anon, authenticated;

-- Stands and top covers go to the Stand Maker; aquariums, sumps and everything else to the Tank Maker
-- (same split as Online Orders' _online_order_line_part, without its "custom" requirement - restock
-- items are regular catalog items).
create or replace function public._production_line_part(p_description text, p_item_code text)
returns text
language sql
immutable
as $$
  select case
    when (coalesce(p_description, '') || ' ' || coalesce(p_item_code, '')) ~* '(stand(?!ard)|top[[:space:]_-]*cover)' then 'stand'
    else 'tank'
  end;
$$;

revoke execute on function public._production_line_part(text, text) from public, anon, authenticated;

-- Same rule as admin_get_online_order_serial_requirements (supabase_online_order_to_ship_serials.sql),
-- so every unit built here is one Ready to Ship will ask a serial for.
create or replace function public._production_item_needs_serial(p_item_code text, p_variant_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select upper(p_item_code) like 'AQ-%'
      or upper(p_item_code) like 'CUSTOM-AQUARIUM%'
      or upper(p_item_code) like 'CUSTOM\_STAND%'
      or upper(p_item_code) like 'CUSTOM-SUMP%'
      or upper(p_item_code) like 'CUSTOM\_SUMP%'
      or coalesce((
        select c."IsProductionCategory"
        from public."Categories" c
        where c."Code" = coalesce(
          (select v."CategoryCode" from public."Variants" v where v."VariationId" = nullif(trim(coalesce(p_variant_id, '')), '')),
          (select i."CategoryCode" from public."Items" i where i."Code" = p_item_code)
        )
      ), false);
$$;

revoke execute on function public._production_item_needs_serial(text, text) from public, anon, authenticated;

-- Next serial in the desktop's format (ProductSerialTrackingForm.InsertSerialRecord):
-- RS-<ItemCode>-<YY>-<6-digit running no. per item per year>. Serialised per item so two postings
-- can't hand out the same number.
create or replace function public._production_next_serial_no(p_item_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year text := to_char(now() at time zone 'Asia/Manila', 'YY');
  v_prefix_rs text := 'RS-' || p_item_code || '-' || v_year || '-';
  v_prefix text := p_item_code || '-' || v_year || '-';
  v_next int;
begin
  perform pg_advisory_xact_lock(hashtext('serialno|' || p_item_code));

  select coalesce(max(right(s."SerialNo", 6)::int), 0) + 1 into v_next
  from public."ItemSerialTracking" s
  where s."ItemCode" = p_item_code
    and (left(s."SerialNo", length(v_prefix_rs)) = v_prefix_rs or left(s."SerialNo", length(v_prefix)) = v_prefix)
    and right(s."SerialNo", 6) ~ '^[0-9]{6}$';

  return v_prefix_rs || lpad(v_next::text, 6, '0');
end;
$$;

revoke execute on function public._production_next_serial_no(text) from public, anon, authenticated;

-- ============================================================================
-- 4. Reading
-- ============================================================================

drop function if exists public.staff_list_production_orders(text, text, text, text, boolean, int, int);

-- Managers see every order. Anyone else only sees Released orders they are a maker on (their My
-- Assignments) - p_assigned_to_me is forced on for them.
create or replace function public.staff_list_production_orders(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_assigned_to_me boolean default false,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  order_no text, description text, warehouse_id text, warehouse_name text, status text, due_date date, notes text,
  tank_maker text, tank_maker_name text, stand_maker text, stand_maker_name text,
  tank_done_at timestamptz, stand_done_at timestamptz,
  needs_tank boolean, needs_stand boolean,
  line_count int, total_quantity numeric, total_output numeric,
  created_by text, created_at timestamptz, released_at timestamptz, finished_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_manager boolean;
  v_mine boolean;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_status text := nullif(trim(coalesce(p_status, '')), '');
  v_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_offset int := (greatest(coalesce(p_page, 1), 1) - 1) * least(greatest(coalesce(p_page_size, 50), 1), 200);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_manager := public._production_is_manager(p_admin_username);
  v_mine := coalesce(p_assigned_to_me, false) or not v_manager;

  return query
    with agg as (
      select l."ProdOrderNo" as prod_no,
             count(*)::int as line_count,
             sum(l."Quantity") as total_quantity,
             sum(l."QtyOutput") as total_output,
             bool_or(l."Part" = 'tank') as needs_tank,
             bool_or(l."Part" = 'stand') as needs_stand
      from public."ProductionOrderLines" l
      group by l."ProdOrderNo"
    )
    select o."No"::text, o."Description"::text, o."WarehouseId"::text, w."Name"::text, o."Status"::text,
           o."DueDate", o."Notes"::text,
           o."TankMaker"::text, coalesce(nullif(trim(tm."DisplayName"), ''), o."TankMaker")::text,
           o."StandMaker"::text, coalesce(nullif(trim(sm."DisplayName"), ''), o."StandMaker")::text,
           o."TankDoneAtUtc", o."StandDoneAtUtc",
           coalesce(a.needs_tank, false), coalesce(a.needs_stand, false),
           coalesce(a.line_count, 0), coalesce(a.total_quantity, 0), coalesce(a.total_output, 0),
           o."CreatedBy"::text, o."CreatedAtUtc", o."ReleasedAtUtc", o."FinishedAtUtc",
           count(*) over ()
    from public."ProductionOrders" o
    left join agg a on a.prod_no = o."No"
    left join public."Warehouses" w on w."ID" = o."WarehouseId"
    left join public."StaffUsers" tm on tm."Username" = o."TankMaker"
    left join public."StaffUsers" sm on sm."Username" = o."StandMaker"
    where (v_status is null
        or o."Status" = v_status
        or (v_status = 'Active' and o."Status" in ('Open', 'Released'))) -- supabase_production_finished_orders_view.sql
      and (not v_mine or (o."Status" = 'Released' and (
            (o."TankMaker" = p_admin_username and coalesce(a.needs_tank, false))
         or (o."StandMaker" = p_admin_username and coalesce(a.needs_stand, false)))))
      and (v_search is null
        or o."No" ilike '%' || v_search || '%'
        or coalesce(o."Description", '') ilike '%' || v_search || '%'
        or exists (select 1 from public."ProductionOrderLines" l
                   where l."ProdOrderNo" = o."No"
                     and (l."ItemCode" ilike '%' || v_search || '%' or coalesce(l."Description", '') ilike '%' || v_search || '%')))
    order by case o."Status" when 'Released' then 0 when 'Open' then 1 else 2 end,
             o."FinishedAtUtc" desc nulls last,
             o."DueDate" nulls last, o."CreatedAtUtc" desc
    limit v_size offset v_offset;
end;
$$;

grant execute on function public.staff_list_production_orders(text, text, text, text, boolean, int, int) to anon;

drop function if exists public.staff_list_production_order_lines(text, text, text);

create or replace function public.staff_list_production_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(
  line_no bigint, item_code text, item_name text, variant_id text, variant_name text, description text,
  quantity numeric, qty_output numeric, part text, needs_serial boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not public._production_is_manager(p_admin_username) and not exists (
    select 1 from public."ProductionOrders" o
    where o."No" = p_no and (o."TankMaker" = p_admin_username or o."StandMaker" = p_admin_username)
  ) then
    raise exception 'You are not assigned to production order %.', p_no;
  end if;

  return query
    select l."LineNo", l."ItemCode"::text, i."Name"::text, l."VariantId"::text,
           coalesce(nullif(trim(v."VariantName"), ''), v."SKU")::text, l."Description"::text,
           l."Quantity", l."QtyOutput", l."Part"::text,
           public._production_item_needs_serial(coalesce(v."ItemCode", l."ItemCode"), l."VariantId")
    from public."ProductionOrderLines" l
    left join public."Items" i on i."Code" = l."ItemCode"
    left join public."Variants" v on v."VariationId" = l."VariantId"
    where l."ProdOrderNo" = p_no
    order by l."LineNo";
end;
$$;

grant execute on function public.staff_list_production_order_lines(text, text, text) to anon;

-- Serials this order's output created (for the card and label printing).
drop function if exists public.staff_list_production_order_serials(text, text, text);

create or replace function public.staff_list_production_order_serials(
  p_admin_username text,
  p_admin_password text,
  p_no text
)
returns table(serial_no text, item_code text, item_description text, variant_code text, location text, status text, entry_no bigint, posted_at timestamptz)
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
           s."Location"::text, s."Status"::text, o."EntryNo", o."PostedAtUtc"
    from public."ProductionOrderOutputs" o
    join public."ProductionOrderOutputSerials" os on os."EntryNo" = o."EntryNo"
    join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
    where o."ProdOrderNo" = p_no
    order by o."EntryNo", s."SerialNo";
end;
$$;

grant execute on function public.staff_list_production_order_serials(text, text, text) to anon;

-- ============================================================================
-- 5. Creating / editing
-- ============================================================================

drop function if exists public.staff_save_production_order(text, text, text, text, text, date, text, text, text, jsonb);

-- Creates (p_no null) or updates an order, header and lines together.
-- p_lines: [{"line_no": 12 or null, "item_code": "...", "variant_id": "..." or null,
--            "description": "...", "quantity": 5}]
-- A saved line missing from p_lines is removed (only if nothing was output on it yet). A line that
-- has output keeps its item/variant and can't drop below what was already output.
create or replace function public.staff_save_production_order(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_description text,
  p_warehouse_id text,
  p_due_date date,
  p_notes text,
  p_tank_maker text,
  p_stand_maker text,
  p_lines jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_no text := nullif(trim(coalesce(p_no, '')), '');
  v_status text;
  v_tank text := nullif(trim(coalesce(p_tank_maker, '')), '');
  v_stand text := nullif(trim(coalesce(p_stand_maker, '')), '');
  v_line jsonb;
  v_line_no bigint;
  v_item text;
  v_variant text;
  v_qty numeric;
  v_desc text;
  v_existing public."ProductionOrderLines";
  v_keep bigint[] := '{}';
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Production Manager can create or edit production orders.';
  end if;

  if not exists (select 1 from public."Warehouses" where "ID" = p_warehouse_id) then
    raise exception 'Pick the warehouse the finished units go into.';
  end if;
  if v_tank is not null and not exists (select 1 from public."StaffUsers" where "Username" = v_tank and "IsActive" and 'TankMaker' = any(coalesce("StaffRoles", '{}'))) then
    raise exception '% is not an active Tank Maker.', v_tank;
  end if;
  if v_stand is not null and not exists (select 1 from public."StaffUsers" where "Username" = v_stand and "IsActive" and 'StandMaker' = any(coalesce("StaffRoles", '{}'))) then
    raise exception '% is not an active Stand Maker.', v_stand;
  end if;
  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) = 0 then
    raise exception 'Add at least one line.';
  end if;

  if v_no is null then
    v_no := 'PRD-' || lpad(nextval('public.production_order_no_seq')::text, 6, '0');
    insert into public."ProductionOrders" ("No", "Description", "WarehouseId", "DueDate", "Notes", "TankMaker", "StandMaker", "CreatedBy")
    values (v_no, nullif(trim(coalesce(p_description, '')), ''), p_warehouse_id, p_due_date,
            nullif(trim(coalesce(p_notes, '')), ''), v_tank, v_stand, p_admin_username);
  else
    select "Status" into v_status from public."ProductionOrders" where "No" = v_no for update;
    if not found then
      raise exception 'Production order % not found.', v_no;
    end if;
    if v_status = 'Finished' then
      raise exception 'Production order % is Finished and can no longer be changed.', v_no;
    end if;
    if exists (select 1 from public."ProductionOrderOutputs" where "ProdOrderNo" = v_no)
       and p_warehouse_id <> (select "WarehouseId" from public."ProductionOrders" where "No" = v_no) then
      raise exception 'Output has already been posted to this order''s warehouse - the warehouse can''t change now.';
    end if;

    update public."ProductionOrders"
      set "Description" = nullif(trim(coalesce(p_description, '')), ''),
          "WarehouseId" = p_warehouse_id,
          "DueDate" = p_due_date,
          "Notes" = nullif(trim(coalesce(p_notes, '')), ''),
          -- A new maker starts the part fresh.
          "TankDoneAtUtc" = case when "TankMaker" is distinct from v_tank then null else "TankDoneAtUtc" end,
          "StandDoneAtUtc" = case when "StandMaker" is distinct from v_stand then null else "StandDoneAtUtc" end,
          "TankMaker" = v_tank,
          "StandMaker" = v_stand,
          "UpdatedAtUtc" = now()
      where "No" = v_no;
  end if;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_line_no := nullif(v_line->>'line_no', '')::bigint;
    v_item := nullif(trim(coalesce(v_line->>'item_code', '')), '');
    v_variant := nullif(trim(coalesce(v_line->>'variant_id', '')), '');
    v_qty := nullif(v_line->>'quantity', '')::numeric;
    v_desc := nullif(trim(coalesce(v_line->>'description', '')), '');

    if v_item is null then
      raise exception 'Every line needs an item.';
    end if;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Item % needs a quantity above zero.', v_item;
    end if;
    if not exists (select 1 from public."Items" where "Code" = v_item) then
      raise exception 'Item "%" does not exist.', v_item;
    end if;
    -- Same item/variant check the ledger will apply at output time - fail now, not on the shop floor.
    perform 1 from public._ile_resolve_stock_key(v_item, v_variant);
    if public._production_item_needs_serial(coalesce((select v."ItemCode" from public."Variants" v where v."VariationId" = v_variant), v_item), v_variant)
       and v_qty <> trunc(v_qty) then
      raise exception 'Item % is serial-tracked - its quantity must be a whole number.', v_item;
    end if;

    if v_line_no is not null then
      select * into v_existing from public."ProductionOrderLines" where "LineNo" = v_line_no and "ProdOrderNo" = v_no;
      if not found then
        raise exception 'Line % is not on order %.', v_line_no, v_no;
      end if;
      if v_existing."QtyOutput" > 0 and (v_existing."ItemCode" <> v_item or coalesce(v_existing."VariantId", '') <> coalesce(v_variant, '')) then
        raise exception 'Item % already has output posted - its item/variant can''t change.', v_existing."ItemCode";
      end if;
      if v_qty < v_existing."QtyOutput" then
        raise exception 'Item % already has % output - the quantity can''t go below that.', v_item, v_existing."QtyOutput";
      end if;
      update public."ProductionOrderLines"
        set "ItemCode" = v_item, "VariantId" = v_variant, "Description" = v_desc, "Quantity" = v_qty,
            "Part" = public._production_line_part(v_desc, v_item)
        where "LineNo" = v_line_no;
    else
      insert into public."ProductionOrderLines" ("ProdOrderNo", "ItemCode", "VariantId", "Description", "Quantity", "Part")
      values (v_no, v_item, v_variant, v_desc, v_qty, public._production_line_part(v_desc, v_item))
      returning "LineNo" into v_line_no;
    end if;
    v_keep := v_keep || v_line_no;
  end loop;

  if exists (select 1 from public."ProductionOrderLines" where "ProdOrderNo" = v_no and "LineNo" <> all(v_keep) and "QtyOutput" > 0) then
    raise exception 'A line that already has output can''t be removed.';
  end if;
  delete from public."ProductionOrderLines" where "ProdOrderNo" = v_no and "LineNo" <> all(v_keep);

  -- Editing a Released order can complete it (e.g. a line reduced to what was already output).
  update public."ProductionOrders"
    set "Status" = 'Finished', "FinishedAtUtc" = now()
    where "No" = v_no and "Status" = 'Released'
      and not exists (select 1 from public."ProductionOrderLines" l where l."ProdOrderNo" = v_no and l."QtyOutput" < l."Quantity");

  return v_no;
end;
$$;

grant execute on function public.staff_save_production_order(text, text, text, text, text, date, text, text, text, jsonb) to anon;

drop function if exists public.staff_set_production_order_released(text, text, text, boolean);

-- Release (Open -> Released: makers see it) or back to Open (only while nothing was output).
create or replace function public.staff_set_production_order_released(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_released boolean
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."ProductionOrders";
  v_needs_tank boolean;
  v_needs_stand boolean;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Production Manager can release production orders.';
  end if;

  select * into v_order from public."ProductionOrders" where "No" = p_no for update;
  if not found then
    raise exception 'Production order % not found.', p_no;
  end if;

  if coalesce(p_released, false) then
    if v_order."Status" <> 'Open' then
      raise exception 'Only an Open order can be released (this one is %).', v_order."Status";
    end if;
    select bool_or("Part" = 'tank'), bool_or("Part" = 'stand') into v_needs_tank, v_needs_stand
      from public."ProductionOrderLines" where "ProdOrderNo" = p_no;
    if v_needs_tank is null then
      raise exception 'Add at least one line before releasing.';
    end if;
    if v_needs_tank and v_order."TankMaker" is null then
      raise exception 'Assign a Tank Maker before releasing - this order has aquarium/sump lines.';
    end if;
    if v_needs_stand and v_order."StandMaker" is null then
      raise exception 'Assign a Stand Maker before releasing - this order has stand lines.';
    end if;
    update public."ProductionOrders" set "Status" = 'Released', "ReleasedAtUtc" = now(), "UpdatedAtUtc" = now() where "No" = p_no;
    return 'Released';
  end if;

  if v_order."Status" <> 'Released' then
    raise exception 'Only a Released order can be reopened (this one is %).', v_order."Status";
  end if;
  if exists (select 1 from public."ProductionOrderLines" where "ProdOrderNo" = p_no and "QtyOutput" > 0) then
    raise exception 'Output has already been posted on this order - it can''t go back to Open.';
  end if;
  update public."ProductionOrders" set "Status" = 'Open', "ReleasedAtUtc" = null, "UpdatedAtUtc" = now() where "No" = p_no;
  return 'Open';
end;
$$;

grant execute on function public.staff_set_production_order_released(text, text, text, boolean) to anon;

drop function if exists public.staff_delete_production_order(text, text, text);

create or replace function public.staff_delete_production_order(
  p_admin_username text,
  p_admin_password text,
  p_no text
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
  if not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Production Manager can delete production orders.';
  end if;
  if exists (select 1 from public."ProductionOrderOutputs" where "ProdOrderNo" = p_no) then
    raise exception 'Output has been posted on % - it can''t be deleted. Reverse the output on Item Ledger Entries first.', p_no;
  end if;
  delete from public."ProductionOrders" where "No" = p_no;
  if not found then
    raise exception 'Production order % not found.', p_no;
  end if;
end;
$$;

grant execute on function public.staff_delete_production_order(text, text, text) to anon;

-- ============================================================================
-- 6. Makers: Production Done
-- ============================================================================

drop function if exists public.staff_set_production_order_part_done(text, text, text, text, boolean);

-- p_part 'tank' | 'stand'. The maker assigned to that part, or a Production Manager.
create or replace function public.staff_set_production_order_part_done(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_part text,
  p_done boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."ProductionOrders";
  v_part text := lower(trim(coalesce(p_part, '')));
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_part not in ('tank', 'stand') then
    raise exception 'p_part must be ''tank'' or ''stand''.';
  end if;

  select * into v_order from public."ProductionOrders" where "No" = p_no for update;
  if not found then
    raise exception 'Production order % not found.', p_no;
  end if;
  if v_order."Status" <> 'Released' then
    raise exception 'Production order % is %, not Released.', p_no, v_order."Status";
  end if;
  if not public._production_is_manager(p_admin_username)
     and p_admin_username is distinct from (case v_part when 'tank' then v_order."TankMaker" else v_order."StandMaker" end) then
    raise exception 'You are not the % Maker on %.', initcap(v_part), p_no;
  end if;

  if v_part = 'tank' then
    update public."ProductionOrders" set "TankDoneAtUtc" = case when p_done then now() end, "UpdatedAtUtc" = now() where "No" = p_no;
  else
    update public."ProductionOrders" set "StandDoneAtUtc" = case when p_done then now() end, "UpdatedAtUtc" = now() where "No" = p_no;
  end if;
end;
$$;

grant execute on function public.staff_set_production_order_part_done(text, text, text, text, boolean) to anon;

-- ============================================================================
-- 7. Posting output
-- ============================================================================

drop function if exists public.staff_post_production_output(text, text, text, jsonb, date);

-- p_lines: [{"line_no": 12, "quantity": 5}] - what was finished now. All-or-nothing: one bad line
-- leaves nothing posted and no serials created.
create or replace function public.staff_post_production_output(
  p_admin_username text,
  p_admin_password text,
  p_no text,
  p_lines jsonb,
  p_posting_date date default null
)
returns table(line_no bigint, item_code text, quantity numeric, entry_no bigint, serial_nos text[], order_status text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."ProductionOrders";
  v_warehouse_name text;
  v_transaction_no bigint;
  v_req jsonb;
  v_line public."ProductionOrderLines";
  v_qty numeric;
  v_entry_no bigint;
  v_serial_item text;
  v_serial_variant text;
  v_serial_desc text;
  v_serial_no text;
  v_running bigint;
  v_serials text[];
  v_status text;
  v_posted int := 0;
  i int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Production Manager can post output.';
  end if;

  select * into v_order from public."ProductionOrders" where "No" = p_no for update;
  if not found then
    raise exception 'Production order % not found.', p_no;
  end if;
  if v_order."Status" <> 'Released' then
    raise exception 'Output can only be posted on a Released order (% is %).', p_no, v_order."Status";
  end if;
  select "Name" into v_warehouse_name from public."Warehouses" where "ID" = v_order."WarehouseId";

  v_transaction_no := nextval('public.ile_transaction_no_seq');

  for v_req in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_qty := coalesce(nullif(v_req->>'quantity', '')::numeric, 0);
    continue when v_qty = 0;

    select * into v_line from public."ProductionOrderLines" l
      where l."LineNo" = (v_req->>'line_no')::bigint and l."ProdOrderNo" = p_no
      for update;
    if not found then
      raise exception 'Line % is not on order %.', v_req->>'line_no', p_no;
    end if;
    if v_qty < 0 then
      raise exception 'Output for % can''t be negative - reverse it on Item Ledger Entries instead.', v_line."ItemCode";
    end if;
    if v_line."QtyOutput" + v_qty > v_line."Quantity" then
      raise exception '% only has % left to output (tried %).', v_line."ItemCode", v_line."Quantity" - v_line."QtyOutput", v_qty;
    end if;

    -- The serial carries the resolved item (a variant with its own item row) and the raw
    -- VariationId - exactly what Ready to Ship's picker matches on. An item with a single variant
    -- still gets that variant's id, since online order lines always carry one.
    v_serial_item := coalesce((select v."ItemCode" from public."Variants" v where v."VariationId" = v_line."VariantId"), v_line."ItemCode");
    v_serial_variant := coalesce(v_line."VariantId",
      (select min(v."VariationId") from public."Variants" v where v."ItemCode" = v_serial_item having count(*) = 1));

    if public._production_item_needs_serial(v_serial_item, v_line."VariantId") and v_qty <> trunc(v_qty) then
      raise exception 'Item % is serial-tracked - output must be a whole number.', v_line."ItemCode";
    end if;

    v_entry_no := public._ile_post(
      'Output', v_line."ItemCode", v_line."VariantId", v_order."WarehouseId", v_qty,
      coalesce(p_posting_date, public._ile_today()), 'Production Output', p_no,
      coalesce(v_line."Description", v_line."ItemCode"), v_transaction_no, p_admin_username
    );

    insert into public."ProductionOrderOutputs" ("EntryNo", "TransactionNo", "ProdOrderNo", "LineNo", "Quantity", "PostedBy")
    values (v_entry_no, v_transaction_no, p_no, v_line."LineNo", v_qty, p_admin_username);

    v_serials := '{}';
    if public._production_item_needs_serial(v_serial_item, v_line."VariantId") then
      v_serial_desc := left(coalesce(nullif(trim(v_line."Description"), ''),
        (select it."Name" from public."Items" it where it."Code" = v_serial_item), v_serial_item), 255);
      for i in 1 .. v_qty::int loop
        v_serial_no := public._production_next_serial_no(v_serial_item);
        insert into public."ItemSerialTracking"
          ("SerialNo", "ItemCode", "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedBy", "VariantCode")
        values (v_serial_no, v_serial_item, v_serial_desc, v_warehouse_name, 'IN_STOCK', p_no, p_admin_username, v_serial_variant)
        returning "RunningSerialNo" into v_running;
        insert into public."ProductionOrderOutputSerials" ("EntryNo", "RunningSerialNo") values (v_entry_no, v_running);
        v_serials := v_serials || v_serial_no;
      end loop;
    end if;

    update public."ProductionOrderLines" set "QtyOutput" = "QtyOutput" + v_qty where "LineNo" = v_line."LineNo";
    v_posted := v_posted + 1;

    line_no := v_line."LineNo";
    item_code := v_line."ItemCode";
    quantity := v_qty;
    entry_no := v_entry_no;
    serial_nos := v_serials;
    order_status := null;
    return next;
  end loop;

  if v_posted = 0 then
    raise exception 'Enter a Qty to Output on at least one line.';
  end if;

  if not exists (select 1 from public."ProductionOrderLines" l where l."ProdOrderNo" = p_no and l."QtyOutput" < l."Quantity") then
    update public."ProductionOrders" set "Status" = 'Finished', "FinishedAtUtc" = now(), "UpdatedAtUtc" = now() where "No" = p_no;
    v_status := 'Finished';
  else
    update public."ProductionOrders" set "UpdatedAtUtc" = now() where "No" = p_no;
    v_status := 'Released';
  end if;

  -- Last row carries the order's new status (the client reads it from any row).
  line_no := null; item_code := null; quantity := null; entry_no := null; serial_nos := null;
  order_status := v_status;
  return next;
end;
$$;

grant execute on function public.staff_post_production_output(text, text, text, jsonb, date) to anon;

-- ============================================================================
-- 8. Reversing output (Item Ledger Entries > Reverse)
-- ============================================================================

-- Copied from supabase_item_ledger_hooks.sql unchanged, plus the 'Production Output' branch at the
-- end: the quantity goes back to its line (a Finished order reopens as Released) and the serials that
-- output created are marked REVERSED. Refused if any of them was already sold or moved away, since
-- the unit then really exists somewhere - correct that with an adjustment instead.
create or replace function public._ile_on_reversed(p_entry public."ItemLedgerEntries")
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line record;
  v_key record;
  v_left numeric;
  v_take numeric;
  v_output public."ProductionOrderOutputs";
  v_warehouse_name text;
  v_bad record;
begin
  if p_entry."DocumentType" in ('Transfer Shipment', 'Transfer Receipt') then
    raise exception 'Transfer entries cannot be reversed here - the transfer document would still say the goods moved. Correct the stock with an adjustment instead.';
  end if;

  -- Sales follow their order automatically (supabase_item_ledger_sales.sql): a hand-made reversal
  -- would be undone on the next pass, since the order would still say the item was sold.
  if p_entry."DocumentType" = 'Sales Order' then
    raise exception 'Sales entries follow their order automatically - cancel or edit the order, or post an adjustment.';
  end if;

  if p_entry."DocumentType" = 'Purchase Receipt' and p_entry."Quantity" > 0 then
    v_left := p_entry."Quantity";

    for v_line in
      select "EntryNo", "ItemCode", "VariantCode", "QtyReceived"
      from public."PurchaseOrderLines"
      where "PONo" = p_entry."DocumentNo"
        and "WarehouseId" = p_entry."WarehouseId"
        and "QtyReceived" > 0
      order by "EntryNo"
    loop
      exit when v_left <= 0;

      begin
        select k.item_code, k.variant_id into v_key
          from public._ile_resolve_stock_key(v_line."ItemCode", nullif(trim(coalesce(v_line."VariantCode", '')), '')) k;
      exception when others then
        continue;
      end;

      if v_key.item_code = p_entry."ItemCode" and coalesce(v_key.variant_id, '') = coalesce(p_entry."VariantId", '') then
        v_take := least(v_left, v_line."QtyReceived");
        update public."PurchaseOrderLines" set "QtyReceived" = "QtyReceived" - v_take where "EntryNo" = v_line."EntryNo";
        v_left := v_left - v_take;
      end if;
    end loop;
  end if;

  -- Production output (supabase_production_orders.sql).
  if p_entry."DocumentType" = 'Production Output' and p_entry."Quantity" > 0 then
    select * into v_output from public."ProductionOrderOutputs" where "EntryNo" = p_entry."EntryNo";
    if found then
      select "Name" into v_warehouse_name from public."Warehouses" where "ID" = p_entry."WarehouseId";

      select s."SerialNo", s."Status", s."Location" into v_bad
        from public."ProductionOrderOutputSerials" os
        join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
        where os."EntryNo" = p_entry."EntryNo"
          and (s."Status" <> 'IN_STOCK' or coalesce(s."Location", '') <> coalesce(v_warehouse_name, ''))
        limit 1;
      if found then
        raise exception 'Serial % from this output is already % at % - it can''t be reversed. Correct the stock with an adjustment instead.',
          v_bad."SerialNo", v_bad."Status", coalesce(v_bad."Location", '(no location)');
      end if;

      update public."ItemSerialTracking" s
        set "Status" = 'REVERSED', "UpdatedAtUtc" = now()
        from public."ProductionOrderOutputSerials" os
        where os."EntryNo" = p_entry."EntryNo" and s."RunningSerialNo" = os."RunningSerialNo";

      update public."ProductionOrderLines"
        set "QtyOutput" = greatest(0, "QtyOutput" - v_output."Quantity")
        where "LineNo" = v_output."LineNo";

      update public."ProductionOrders"
        set "Status" = 'Released', "FinishedAtUtc" = null, "UpdatedAtUtc" = now()
        where "No" = v_output."ProdOrderNo" and "Status" = 'Finished';
    end if;
  end if;
end;
$$;

revoke execute on function public._ile_on_reversed(public."ItemLedgerEntries") from public, anon, authenticated;
