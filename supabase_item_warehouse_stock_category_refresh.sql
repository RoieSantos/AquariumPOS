-- Follow-up to supabase_item_warehouse_stock.sql - per direct request ("I think its syncing a lot
-- of items. can we only sync over selected category?"), refined to: "I want to select in the
-- category setup the category that i want to include on the sync" - NOT a per-click dropdown on
-- the Stock On Hand page itself, but a persistent, portal-owned flag set once on Category Setup
-- (same pattern as that page's existing Production Category / Exclude in Transfer Orders flags),
-- so "Refresh from Pancake" always walks only whichever categories are currently marked included,
-- with no extra step needed at refresh time.
--
-- New Categories."IncludeInStockSync" flag defaults to false (opt-IN, unlike the other two
-- Category Setup flags which default false as opt-OUT) - per "select the category that i want to
-- include", nothing syncs until a super user actually turns some categories on. Refreshing only
-- clears/replaces cache rows for categories currently in scope - a category later un-checked just
-- stops being refreshed going forward, its last-known cached rows aren't deleted out from under it.

alter table public."Categories" add column if not exists "IncludeInStockSync" boolean not null default false;

drop function if exists public.admin_list_categories(text, text);

create or replace function public.admin_list_categories(p_admin_username text, p_admin_password text)
returns table(code text, description text, is_production_category boolean, exclude_in_transfer_orders boolean, include_in_stock_sync boolean, item_count bigint)
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
           coalesce(c."ExcludeInTransferOrders", false), coalesce(c."IncludeInStockSync", false), count(*)
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where i."CategoryCode" is not null and trim(i."CategoryCode") <> ''
    group by i."CategoryCode", c."Description", c."IsProductionCategory", c."ExcludeInTransferOrders", c."IncludeInStockSync"
    order by i."CategoryCode";
end;
$$;

drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean);
drop function if exists public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean);

create or replace function public.admin_update_category_flags(
  p_admin_username text,
  p_admin_password text,
  p_code text,
  p_description text,
  p_is_production_category boolean,
  p_exclude_in_transfer_orders boolean,
  p_include_in_stock_sync boolean
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

  insert into public."Categories" ("Code", "Description", "IsProductionCategory", "ExcludeInTransferOrders", "IncludeInStockSync")
  values (p_code, nullif(trim(p_description), ''), coalesce(p_is_production_category, false), coalesce(p_exclude_in_transfer_orders, false), coalesce(p_include_in_stock_sync, false))
  on conflict ("Code") do update
    set "Description" = excluded."Description",
        "IsProductionCategory" = excluded."IsProductionCategory",
        "ExcludeInTransferOrders" = excluded."ExcludeInTransferOrders",
        "IncludeInStockSync" = excluded."IncludeInStockSync";
end;
$$;

grant execute on function public.admin_list_categories(text, text) to anon;
grant execute on function public.admin_update_category_flags(text, text, text, text, boolean, boolean, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Stock On Hand refresh - now scoped to Categories."IncludeInStockSync" = true instead of walking
-- every product in the whole catalog. No client-supplied category param anymore - the scope lives
-- entirely in Category Setup, so every "Refresh from Pancake" click (regardless of what the Stock
-- On Hand page's own Category filter happens to be set to for VIEWING) always syncs the same
-- configured set.
-- ---------------------------------------------------------------------------

drop function if exists public.staff_start_item_warehouse_stock_refresh(text, text);
drop function if exists public.staff_start_item_warehouse_stock_refresh(text, text, text);

create or replace function public.staff_start_item_warehouse_stock_refresh(
  p_admin_username text,
  p_admin_password text
)
returns table(product_id text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  delete from public."ItemWarehouseStockCache" c
  using public."Categories" cat
  where cat."Code" = c."CategoryCode"
    and cat."IncludeInStockSync" is true;

  return query
    select distinct p.product_id::text from (
      select i."ProductId" as product_id
      from public."Items" i
      join public."Categories" cat on cat."Code" = i."CategoryCode"
      where i."ProductId" is not null and trim(i."ProductId") <> '' and cat."IncludeInStockSync" is true
      union
      select v."ProductId" as product_id
      from public."Variants" v
      join public."Categories" cat on cat."Code" = v."CategoryCode"
      where v."ProductId" is not null and trim(v."ProductId") <> '' and cat."IncludeInStockSync" is true
    ) p
    order by 1;
end;
$$;

grant execute on function public.staff_start_item_warehouse_stock_refresh(text, text) to anon;

-- ---------------------------------------------------------------------------
-- Stock On Hand's own Category filter dropdown - per "when I open stock on hand I only need to
-- show the ones included on stock on hand in the category setup". Deliberately a NEW function
-- rather than changing staff_list_categories (docs/js/serialTracker.js also calls that one, for
-- an unrelated picker that has no reason to be scoped to stock-sync categories), so this only
-- affects Stock On Hand's dropdown. No Items join needed - a category can only ever be flagged
-- IncludeInStockSync in the first place via Category Setup, whose own list already only shows
-- codes actually used on Items.
-- ---------------------------------------------------------------------------
drop function if exists public.staff_list_stock_sync_categories(text, text);

create or replace function public.staff_list_stock_sync_categories(p_admin_username text, p_admin_password text)
returns table(code text, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select c."Code"::text, coalesce(nullif(trim(c."Description"), ''), c."Code")::text
    from public."Categories" c
    where c."IncludeInStockSync" is true
    order by 2;
end;
$$;

grant execute on function public.staff_list_stock_sync_categories(text, text) to anon;

-- ---------------------------------------------------------------------------
-- staff_list_item_warehouse_stock (the main Stock On Hand table itself) - scoped to
-- Categories."IncludeInStockSync" = true (per "only show the ones included on stock on hand in
-- the category setup" - without this, any cache rows left over from BEFORE this feature existed,
-- when Refresh from Pancake still synced the whole catalog, would keep showing under "All
-- categories" forever, since a scoped refresh only ever touches included categories' rows and
-- never purges anyone else's), and adds a Vendor/Supplier column + filter (per "I want a field on
-- the items 'Vendor No.'... whenever we run a report it will show who is the supplier").
--
-- Vendor is read LIVE via a join to Items, not cached onto ItemWarehouseStockCache the way
-- CategoryCode is - per direct follow-up question ("once I update the vendor field per item.. will
-- it flow through the stock on hand?"): caching it would mean a vendor tag change (Item Setup's
-- factbox or bulk import) sits invisible until the next Refresh from Pancake, which is a real
-- Pancake quantity resync with no reason to be required just because a portal-only vendor tag
-- changed. A plain indexed join on Items.Code costs nothing extra and is always current.
--
-- No new vendor-lookup RPC needed for the filter dropdown - staff_search_vendors already exists
-- (supabase_vendor_tables.sql, staff-gated, same one the Delivery page uses).
-- ---------------------------------------------------------------------------

drop function if exists public.staff_list_item_warehouse_stock(text, text, text, text, text);
drop function if exists public.staff_list_item_warehouse_stock(text, text, text, text, text, text);

create or replace function public.staff_list_item_warehouse_stock(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text default null,
  p_search text default null,
  p_category_code text default null,
  p_vendor_code text default null
)
returns table(
  item_code text,
  item_name text,
  category_code text,
  category_name text,
  vendor_code text,
  vendor_name text,
  warehouse_id text,
  warehouse_name text,
  remain_quantity numeric,
  last_refreshed_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      c."ItemCode"::text,
      coalesce(nullif(trim(c."ItemName"), ''), c."ItemCode")::text,
      c."CategoryCode"::text,
      coalesce(cat."Description", c."CategoryCode")::text as category_name,
      itm."VendorCode"::text,
      v_vendor."Name"::text as vendor_name,
      c."WarehouseId"::text,
      coalesce(w."Name", c."WarehouseId")::text as warehouse_name,
      c."RemainQuantity",
      (select max("FetchedAtUtc") from public."ItemWarehouseStockCache")
    from public."ItemWarehouseStockCache" c
    left join public."Warehouses" w on w."ID" = c."WarehouseId"
    left join public."Categories" cat on cat."Code" = c."CategoryCode"
    left join public."Items" itm on itm."Code" = c."ItemCode"
    left join public."Vendors" v_vendor on v_vendor."VendorCode" = itm."VendorCode"
    where c."ItemCode" is not null
      and coalesce(cat."IncludeInStockSync", false) is true
      and (p_warehouse_id is null or trim(p_warehouse_id) = '' or c."WarehouseId" = p_warehouse_id)
      and (p_category_code is null or trim(p_category_code) = '' or c."CategoryCode" = p_category_code)
      and (p_vendor_code is null or trim(p_vendor_code) = '' or itm."VendorCode" = p_vendor_code)
      and (
        p_search is null or trim(p_search) = ''
        or c."ItemCode" ilike '%' || trim(p_search) || '%'
        or c."ItemName" ilike '%' || trim(p_search) || '%'
      )
    order by coalesce(nullif(trim(c."ItemName"), ''), c."ItemCode"), warehouse_name;
end;
$$;

grant execute on function public.staff_list_item_warehouse_stock(text, text, text, text, text, text) to anon;
