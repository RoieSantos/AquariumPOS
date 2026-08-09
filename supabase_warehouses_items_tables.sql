-- Supabase/Postgres mirrors of the local dbo.Warehouses and dbo.Items master data tables.
--
-- Synced one-way (desktop -> Supabase) automatically by the AquariumPOS desktop app:
--   - OnlinefunctionsEvents.SyncWarehousesToSupabaseAsync()
--   - OnlinefunctionsEvents.SyncItemsToSupabaseAsync()
-- Both run every 5 minutes via MainForm's masterDataSyncTimer, using the same
-- exists-check-then-POST/PATCH pattern already used for Transfer Orders and
-- ItemSerialTracking (see supabase_item_serial_tracking.sql).
--
-- SECURITY NOTE: unlike the Web Portal-facing tables, these are NOT opened up to the
-- "anon" role. The desktop app authenticates its Supabase REST calls with the
-- SECRET/service-role key (GlobalSettings.TransferHeaderSupabaseAuthorization), which
-- bypasses Row Level Security entirely, so no anon/authenticated policies are required
-- for the sync itself to work. Items carries Cost/pricing data, so RLS is intentionally
-- left closed (no policies) until/unless a Web Portal feature explicitly needs to read
-- this data - at that point, add narrowly-scoped SELECT-only anon policies similar to
-- the ones in supabase_web_portal_rls_policies.sql.

create table if not exists public."Warehouses" (
    "ID" varchar(100) primary key,
    "Name" varchar(200),
    "IsProductionWarehouse" boolean not null default false,
    "IsStockWarehouse" boolean not null default false,
    "SalesTarget" numeric(18, 4),
    "SyncedAtUtc" timestamptz
);

-- Warehouses may already exist from before "SalesTarget" was added - add it if missing (no-op
-- otherwise). Local-only field, same as IsProductionWarehouse/IsStockWarehouse - Pancake doesn't
-- provide it, so it's never touched by admin_sync_warehouses_from_pancake and is only ever set
-- from the Web Portal (Warehouse Setup's inline "Save" per row).
alter table public."Warehouses" add column if not exists "SalesTarget" numeric(18, 4);

-- Portal-only "Active" flag, same local-only pattern as SalesTarget - not sourced from Pancake or
-- the desktop sync, only ever set from Warehouse Setup. Defaults true so every existing/synced
-- warehouse stays visible in staff_search_warehouses until someone explicitly deactivates it.
alter table public."Warehouses" add column if not exists "IsActive" boolean not null default true;

alter table public."Warehouses" enable row level security;

create table if not exists public."Items" (
    "Code" varchar(200) primary key,
    "Name" varchar(255),
    "Description" varchar(1000),
    "Cost" numeric(18, 4),
    "Price" numeric(18, 4),
    "WholesalePrice" numeric(18, 4),
    "RetailPrice" numeric(18, 4),
    "PromoPrice" numeric(18, 4),
    "CategoryCode" varchar(100),
    "Brand" varchar(150),
    "SKU" varchar(150),
    "QuantityInStock" int,
    "MinimumStock" int,
    "IsActive" boolean,
    "VariationId" varchar(100),
    "ProductId" varchar(100),
    "Images" text,
    "SyncedAtUtc" timestamptz
);

-- Items may already exist from before "Images" was added - add it if missing (no-op otherwise).
alter table public."Items" add column if not exists "Images" text;

alter table public."Items" enable row level security;

-- Mirrors local dbo.[Variant] (see OnlinefunctionsEvents.SyncProductVariationsAsync):
-- one row per Pancake product variation, linked back to the parent Items row.
-- MainItemCode = the parent product's own code (display_id/code from Pancake).
-- ItemCode = the actual local Items.Code this variation resolved/linked to (matched by
-- SKU first, falling back to MainItemCode) - can differ from MainItemCode in edge cases.
create table if not exists public."Variants" (
    "VariationId" varchar(100) primary key,
    "MainItemCode" varchar(200) not null default '',
    "ItemCode" varchar(200),
    "SKU" varchar(150),
    "VariantName" varchar(255),
    "Price" numeric(18, 4),
    "CategoryCode" varchar(100),
    "Images" text,
    "ProductId" varchar(100),
    "SyncedAtUtc" timestamptz
);

-- Variants may already exist from before "ProductId" was added - add it if missing (no-op
-- otherwise). Pancake's own product id for this variant's parent product (not to be confused
-- with VariationId, which identifies the variation itself) - the /products/variations payload
-- carries this per variation (as "product_id" on the flat element), and the sync already staged
-- it in tmp_pancake_variants_resolved for cross-linking onto Items.ProductId; this column just
-- persists that same value directly on the Variant row too, per explicit request.
alter table public."Variants" add column if not exists "ProductId" varchar(100);

create index if not exists "IX_Variants_MainItemCode" on public."Variants" ("MainItemCode");

alter table public."Variants" enable row level security;

-- Portal-only mirror of the local dbo.Category.IsProductionCategory flag (see
-- MainForm.cs's Category Management grid) - keyed by the same CategoryCode text already
-- present on Items/Variants. Deliberately NOT synced from the desktop: IsProductionCategory is a
-- purely manual/local designation there too (Pancake has no concept of it, same as
-- Warehouses.Is_Production_Warehouse before that got a portal column), and per direct decision
-- this is portal-owned - a super user tags codes here independently via Category Setup, the same
-- pattern as Warehouse Setup's portal-only "Active" flag. This can diverge from whatever's set in
-- the desktop's own Category Management grid; there is intentionally no link between them.
create table if not exists public."Categories" (
    "Code" varchar(100) primary key,
    "Description" varchar(255),
    "IsProductionCategory" boolean not null default false
);

-- Categories may already exist from before "ExcludeInTransferOrders" was added - add it if
-- missing (no-op otherwise). Portal-only, same as IsProductionCategory - when true, items under
-- this category are hidden entirely from Transfer Orders' Item No./Variant lookups (staff_search_
-- items/staff_search_variants below), regardless of the "Use Production Category" checkbox state.
alter table public."Categories" add column if not exists "ExcludeInTransferOrders" boolean not null default false;

alter table public."Categories" enable row level security;

-- Read-only "Item & Warehouse Setup" page (Web Portal, super users only).
-- Same trust model as supabase_staff_users_table.sql: there is no real server-side
-- session, so these functions re-verify the acting super user's username + password
-- on every call via public.is_admin_authorized(), rather than opening direct anon
-- SELECT access to these tables (Items carries Cost/pricing data).

drop function if exists public.admin_list_warehouses(text, text);
drop function if exists public.admin_list_warehouses(text, text, int, int);

-- p_page/p_page_size (per portal-wide pagination): total_count is count(*) over() - computed
-- before LIMIT/OFFSET applies - so the client can compute total pages from one call, no separate
-- count query needed. Same pattern applied to every admin_list_* RPC in this file.
create or replace function public.admin_list_warehouses(p_admin_username text, p_admin_password text, p_page int default 1, p_page_size int default 50)
returns table(
  id text,
  name text,
  is_production_warehouse boolean,
  is_stock_warehouse boolean,
  is_active boolean,
  sales_target numeric,
  synced_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "ID"::text, "Name"::text, "IsProductionWarehouse", "IsStockWarehouse", "IsActive", "SalesTarget", "SyncedAtUtc",
           count(*) over()
    from public."Warehouses"
    order by "Name"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_update_warehouse_sales_target(text, text, text, numeric);

-- Sets a warehouse's local-only Sales Target (per Warehouse Setup's inline editable field) -
-- same pattern as admin_update_delivery_stop_geocode: a single narrowly-scoped update, gated by
-- is_admin_authorized (super users only, matching this whole page's access level).
create or replace function public.admin_update_warehouse_sales_target(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
  p_sales_target numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."Warehouses"
  set "SalesTarget" = p_sales_target
  where "ID" = p_warehouse_id;
end;
$$;

drop function if exists public.admin_update_warehouse_flags(text, text, text, boolean, boolean);
drop function if exists public.admin_update_warehouse_flags(text, text, text, boolean, boolean, boolean);

-- Mirrors the Local POS's WarehouseSetupForm checkbox editing of Is_Production_Warehouse /
-- Is_Warehouse_Stocks (dbo.Warehouses), plus IsActive (portal-only, see the column comment
-- above). Note: SyncWarehousesToSupabaseAsync (desktop) PATCHes IsProductionWarehouse/
-- IsStockWarehouse from the local DB on every warehouse sync run, so a portal edit to those two
-- only sticks until the next desktop sync - IsActive has no such conflict since nothing else
-- ever writes it.
create or replace function public.admin_update_warehouse_flags(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
  p_is_production_warehouse boolean,
  p_is_stock_warehouse boolean,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."Warehouses"
  set "IsProductionWarehouse" = p_is_production_warehouse,
      "IsStockWarehouse" = p_is_stock_warehouse,
      "IsActive" = p_is_active
  where "ID" = p_warehouse_id;
end;
$$;

drop function if exists public.admin_list_items(text, text, text);
drop function if exists public.admin_list_items(text, text, text, int, int);

create or replace function public.admin_list_items(p_admin_username text, p_admin_password text, p_search text default null, p_page int default 1, p_page_size int default 50)
returns table(
  code text,
  name text,
  description text,
  cost numeric,
  price numeric,
  wholesale_price numeric,
  retail_price numeric,
  promo_price numeric,
  category_code text,
  brand text,
  sku text,
  quantity_in_stock int,
  minimum_stock int,
  is_active boolean,
  images text,
  synced_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "Code"::text, "Name"::text, "Description"::text, "Cost", "Price", "WholesalePrice", "RetailPrice", "PromoPrice",
           "CategoryCode"::text, "Brand"::text, "SKU"::text, "QuantityInStock", "MinimumStock", "IsActive", "Images"::text, "SyncedAtUtc",
           count(*) over()
    from public."Items"
    where p_search is null or trim(p_search) = '' or "Code" ilike '%' || p_search || '%' or "Name" ilike '%' || p_search || '%'
    order by "Name"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_list_variants(text, text, text);
drop function if exists public.admin_list_variants(text, text, text, text);
drop function if exists public.admin_list_variants(text, text, text, text, int, int);

-- p_main_item_code: exact filter, used when navigating here from a specific Item row (Item
-- Setup's factbox) - callers of that exact-filter path don't pass p_page/p_page_size, so they
-- just get the (1, 50) defaults, plenty for one item's variant list.
-- p_search: free-text ILIKE search (MainItemCode/VariantName/SKU), used for general browsing.
--
-- variant_name: composed and PERSISTED as "ItemCode - Product name" directly on
-- Variants."VariantName" at sync time (see the sync's insert into public."Variants" in
-- supabase_pancake_manual_sync.sql) rather than computed here at query time - this RPC just
-- reads it straight off the table like every other column.
create or replace function public.admin_list_variants(p_admin_username text, p_admin_password text, p_search text default null, p_main_item_code text default null, p_page int default 1, p_page_size int default 50)
returns table(
  variation_id text,
  main_item_code text,
  item_code text,
  sku text,
  variant_name text,
  price numeric,
  category_code text,
  images text,
  synced_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select v."VariationId"::text, v."MainItemCode"::text, v."ItemCode"::text, v."SKU"::text, v."VariantName"::text,
           v."Price", v."CategoryCode"::text, v."Images"::text, v."SyncedAtUtc",
           count(*) over()
    from public."Variants" v
    where (p_main_item_code is not null and trim(p_main_item_code) <> '' and v."MainItemCode" = p_main_item_code)
       or (
         (p_main_item_code is null or trim(p_main_item_code) = '')
         and (
           p_search is null or trim(p_search) = ''
           or v."MainItemCode" ilike '%' || p_search || '%'
           or v."VariantName" ilike '%' || p_search || '%'
           or v."SKU" ilike '%' || p_search || '%'
         )
       )
    order by v."MainItemCode"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_count_variants_by_item(text, text);

-- Returns the set of MainItemCode values that currently have at least one Variant row,
-- so the Items page can show a "View Variants" link only for items that actually have some.
create or replace function public.admin_count_variants_by_item(p_admin_username text, p_admin_password text)
returns table(main_item_code text, variant_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "MainItemCode"::text, count(*)
    from public."Variants"
    group by "MainItemCode";
end;
$$;

drop function if exists public.admin_list_categories(text, text);

-- "Category Setup" page (super users only) - every CategoryCode currently in use on Items,
-- left-joined to the portal-only Categories table so untagged codes still show up (defaulting to
-- not-production, same default as the desktop's Category.IsProductionCategory column). Not
-- paginated - category counts are small enough (a handful to a few dozen) that a full list is
-- fine, same as admin_count_variants_by_item above.
create or replace function public.admin_list_categories(p_admin_username text, p_admin_password text)
returns table(code text, description text, is_production_category boolean, exclude_in_transfer_orders boolean, item_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."CategoryCode"::text, c."Description"::text, coalesce(c."IsProductionCategory", false),
           coalesce(c."ExcludeInTransferOrders", false), count(*)
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where i."CategoryCode" is not null and trim(i."CategoryCode") <> ''
    group by i."CategoryCode", c."Description", c."IsProductionCategory", c."ExcludeInTransferOrders"
    order by i."CategoryCode";
end;
$$;

drop function if exists public.admin_update_category_flags(text, text, text, text, boolean);
drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean);

-- Upserts a category's portal-only Description/IsProductionCategory/ExcludeInTransferOrders -
-- same is_admin_authorized-gated, narrowly-scoped update pattern as admin_update_warehouse_flags.
create or replace function public.admin_update_category_flags(
  p_admin_username text,
  p_admin_password text,
  p_code text,
  p_description text,
  p_is_production_category boolean,
  p_exclude_in_transfer_orders boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  insert into public."Categories" ("Code", "Description", "IsProductionCategory", "ExcludeInTransferOrders")
  values (p_code, nullif(trim(p_description), ''), coalesce(p_is_production_category, false), coalesce(p_exclude_in_transfer_orders, false))
  on conflict ("Code") do update
    set "Description" = excluded."Description",
        "IsProductionCategory" = excluded."IsProductionCategory",
        "ExcludeInTransferOrders" = excluded."ExcludeInTransferOrders";
end;
$$;

drop function if exists public.staff_search_items(text, text, text, int);
drop function if exists public.staff_search_items(text, text, text, int, boolean);

-- Item lookup for staff-facing pickers (e.g. Transfer Orders' line items) - gated by
-- is_staff_authorized (any active staff), NOT is_admin_authorized like admin_list_items above,
-- since Transfer Orders is open to all staff, not just super users. Deliberately narrower than
-- admin_list_items' output - only the fields a picker needs, no Cost/WholesalePrice/etc, keeping
-- the same "pricing data stays super-user-only" intent the table's RLS comment describes.
--
-- p_use_production_category: mirrors the desktop's RefreshItemLookupOptions/ResolveItemInfo,
-- which filter the item catalog to Category.IsProductionCategory = <the header checkbox state>.
-- Null (the default) means no filtering, for any future caller that doesn't care; Transfer
-- Orders always passes the New Transfer Order form's "Use Production Category" checkbox value.
-- Untagged categories (no Categories row yet) default to not-production, same default as the
-- desktop's Category.IsProductionCategory column.
--
-- A blank p_search now returns the first v_limit items (by name) instead of nothing, so clicking
-- into an empty Item No. field shows a browsable starting list - same "click the field, see
-- something" UX as staff_search_warehouses, just capped since the item catalog is much bigger
-- than the warehouse list.
--
-- p_page: same portal-wide pagination pattern as the admin_list_* RPCs - total_count is
-- count(*) over(), letting the dropdown's Prev/Next buttons compute total pages from one call.
--
-- Items whose category is flagged ExcludeInTransferOrders (Category Setup) are always left out,
-- regardless of p_use_production_category - unlike that filter, this isn't a toggle, it's a hard
-- exclusion staff can't work around from this form.
create or replace function public.staff_search_items(p_admin_username text, p_admin_password text, p_search text default null, p_limit int default 20, p_use_production_category boolean default null, p_page int default 1)
returns table(code text, name text, category_code text, quantity_in_stock int, total_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."Code"::text, i."Name"::text, i."CategoryCode"::text, i."QuantityInStock",
           count(*) over()
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where (p_search is null or trim(p_search) = '' or i."Code" ilike '%' || p_search || '%' or i."Name" ilike '%' || p_search || '%')
      and (p_use_production_category is null or coalesce(c."IsProductionCategory", false) = p_use_production_category)
      and not coalesce(c."ExcludeInTransferOrders", false)
    order by i."Name"
    limit v_limit offset (v_page - 1) * v_limit;
end;
$$;

drop function if exists public.staff_search_variants(text, text, text, text, int);
drop function if exists public.staff_search_variants(text, text, text, text, int, boolean);

-- Variant lookup for the same staff-facing pickers - supports BOTH lookup directions Transfer
-- Orders' line picker needs:
--   p_item_code only: every variant of that item (Item was picked first).
--   p_item_code + p_search: that item's variants, further filtered by typed text.
--   p_search only (no p_item_code): free search across all variants (Variant searched first) -
--     item_name is joined in so the caller can auto-fill Item No./Description from whichever
--     variant gets picked, without a second round trip.
-- p_use_production_category: same category filter as staff_search_items above - checked against
-- the variant's own CategoryCode first, falling back to its linked item's CategoryCode.
-- p_page: same portal-wide pagination pattern as staff_search_items above.
-- Same hard ExcludeInTransferOrders exclusion as staff_search_items above.
create or replace function public.staff_search_variants(p_admin_username text, p_admin_password text, p_item_code text default null, p_search text default null, p_limit int default 50, p_use_production_category boolean default null, p_page int default 1)
returns table(variation_id text, main_item_code text, item_code text, sku text, variant_name text, item_name text, quantity_in_stock int, total_count bigint)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_has_item_code boolean := p_item_code is not null and trim(p_item_code) <> '';
  v_has_search boolean := p_search is not null and trim(p_search) <> '';
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not v_has_item_code and not v_has_search then
    return;
  end if;

  return query
    select v."VariationId"::text, v."MainItemCode"::text, v."ItemCode"::text, v."SKU"::text, v."VariantName"::text,
           i."Name"::text, i."QuantityInStock",
           count(*) over()
    from public."Variants" v
    left join public."Items" i on i."Code" = coalesce(v."ItemCode", v."MainItemCode")
    left join public."Categories" cat on cat."Code" = coalesce(v."CategoryCode", i."CategoryCode")
    where
      (p_use_production_category is null or coalesce(cat."IsProductionCategory", false) = p_use_production_category)
      and not coalesce(cat."ExcludeInTransferOrders", false)
      and case
        when v_has_item_code then
          (v."ItemCode" = p_item_code or v."MainItemCode" = p_item_code)
          and (not v_has_search or v."MainItemCode" ilike '%' || p_search || '%' or v."VariantName" ilike '%' || p_search || '%' or v."SKU" ilike '%' || p_search || '%')
        else
          v."MainItemCode" ilike '%' || p_search || '%' or v."VariantName" ilike '%' || p_search || '%' or v."SKU" ilike '%' || p_search || '%'
      end
    order by v."MainItemCode"
    limit v_limit offset (v_page - 1) * v_limit;
end;
$$;

drop function if exists public.staff_search_warehouses(text, text, text, int);

-- Warehouse lookup for the same staff-facing pickers (Transfer Orders' From/To Warehouse
-- fields) - gated by is_staff_authorized like staff_search_items/staff_search_variants above,
-- not is_admin_authorized like admin_list_warehouses (Transfer Orders is open to all staff).
-- Unlike staff_search_items, a blank p_search returns every warehouse (up to the limit) rather
-- than nothing - the warehouse list is small, so "click the field, see the full list" is more
-- useful here than requiring the user to type first.
-- Only IsActive = true warehouses are returned - Warehouse Setup's Active checkbox is how a
-- super user keeps closed/retired warehouses out of Transfer Orders without deleting the row.
create or replace function public.staff_search_warehouses(p_admin_username text, p_admin_password text, p_search text default null, p_limit int default 50)
returns table(id text, name text, is_production_warehouse boolean, is_stock_warehouse boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "ID"::text, "Name"::text, "IsProductionWarehouse", "IsStockWarehouse"
    from public."Warehouses"
    where "IsActive" and (p_search is null or trim(p_search) = '' or "Name" ilike '%' || p_search || '%')
    order by "Name"
    limit v_limit;
end;
$$;

drop function if exists public.staff_next_transfer_no(text, text, text);

-- Generates the next Transfer Order Document No., scoped per destination (To) warehouse:
-- TR-{WarehouseName}0001, TR-{WarehouseName}0002, etc. Portal-owned numbering - the desktop's
-- own Transfer Request flow uses a flat TR-{int} sequence with no warehouse scoping (see
-- TransferHeaderForm.cs's CreateNewTransferHeader), deliberately not reused here, consistent with
-- the portal running its own standalone Transfer Order process. The Prefix/Padding/Starting No.
-- format itself now lives in the 'TRANSFER-ORDER' row of public."NoSeries" (General Setup ->
-- No. Series - see supabase_no_series_tables.sql), with the actual per-warehouse counters kept in
-- public."NoSeriesLine"; this function just authorizes the caller and delegates the increment to
-- _next_no_series_number. p_seed_no carries forward any numbers already issued under the old
-- scan-for-max approach (7-digit padding) so a warehouse with existing orders keeps counting
-- upward instead of appearing to restart at the series' Starting No.
create or replace function public.staff_next_transfer_no(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_legacy_prefix text;
  v_legacy_max int;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_legacy_prefix := 'TR-' || coalesce(p_warehouse_name, '');

  select coalesce(max(substring("No." from length(v_legacy_prefix) + 1)::int), 0)
    into v_legacy_max
    from public."Transfer_Header"
    where "No." like v_legacy_prefix || '%'
      and substring("No." from length(v_legacy_prefix) + 1) ~ '^[0-9]+$';

  return public._next_no_series_number('TRANSFER-ORDER', p_warehouse_name, v_legacy_max);
end;
$$;

-- Direct table access stays fully blocked by RLS (no policies); only the
-- re-verifying functions above are reachable from the portal's anon key.
revoke all on public."Warehouses" from anon, authenticated;
revoke all on public."Items" from anon, authenticated;
revoke all on public."Variants" from anon, authenticated;
revoke all on public."Categories" from anon, authenticated;
grant execute on function public.admin_list_warehouses(text, text, int, int) to anon;
grant execute on function public.admin_update_warehouse_sales_target(text, text, text, numeric) to anon;
grant execute on function public.admin_update_warehouse_flags(text, text, text, boolean, boolean, boolean) to anon;
grant execute on function public.admin_list_items(text, text, text, int, int) to anon;
grant execute on function public.admin_list_variants(text, text, text, text, int, int) to anon;
grant execute on function public.admin_count_variants_by_item(text, text) to anon;
grant execute on function public.admin_list_categories(text, text) to anon;
grant execute on function public.admin_update_category_flags(text, text, text, text, boolean, boolean) to anon;
grant execute on function public.staff_search_items(text, text, text, int, boolean, int) to anon;
grant execute on function public.staff_search_variants(text, text, text, text, int, boolean, int) to anon;
grant execute on function public.staff_search_warehouses(text, text, text, int) to anon;
grant execute on function public.staff_next_transfer_no(text, text, text) to anon;
