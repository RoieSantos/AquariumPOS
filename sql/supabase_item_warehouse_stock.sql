-- "Stock On Hand by Warehouse" report (Web Portal) - per direct request: "a report to see all the
-- items stocks onhand filterable by warehouse location."
--
-- Real per-warehouse stock for regular (non-serial-tracked) items does not exist anywhere in this
-- app's own database (local SQL Server or Supabase) - dbo.Items/public."Items".QuantityInStock is
-- a single global number with no warehouse dimension. The only place real per-warehouse quantity
-- genuinely lives is Pancake (pos.pages.fm), which this app already reads live for Transfer
-- Orders' "available at From Warehouse" column - see staff_get_transfer_line_pancake_stock in
-- supabase_transfer_line_pancake_stock.sql, whose GET /shops/{id}/products/{product_id} +
-- variations[].variations_warehouses[] pattern this file reuses directly.
--
-- That existing RPC only ever looks up a handful of products (whatever's on one Transfer Order),
-- fetched live on modal-open. A full-catalog report can't do the same thing on every page load -
-- with potentially hundreds of distinct products, that's hundreds of sequential Pancake API calls,
-- too slow to run inline. So this is a cache-and-refresh model instead: staff_list_item_warehouse_
-- stock() just reads a cache table (instant, filterable, no live API calls), refilled by a staff-
-- triggered "Refresh from Pancake" button on the report page.
--
-- That refresh is deliberately NOT one big RPC looping over every product - a first attempt at
-- exactly that hit "canceling statement due to statement timeout" on a real catalog, since
-- Supabase enforces a statement_timeout on API-role calls well under how long hundreds of
-- sequential Pancake requests actually take. Instead the refresh is driven from the browser:
-- staff_start_item_warehouse_stock_refresh() truncates the cache and hands back every distinct
-- product id to process; the client then calls staff_refresh_item_warehouse_stock_product() once
-- per product (a few at a time), each call bounded by a single Pancake HTTP request so no
-- individual call can ever approach the timeout, however large the catalog grows.

create table if not exists public."ItemWarehouseStockCache" (
  "Id" bigint generated always as identity primary key,
  "ProductId" text,
  "VariationId" text,
  "ItemCode" text,
  "ItemName" text,
  "CategoryCode" text,
  "WarehouseId" text not null,
  "RemainQuantity" numeric,
  "FetchedAtUtc" timestamptz not null default now()
);

-- ItemWarehouseStockCache may already exist from before "CategoryCode" was added - add it if
-- missing (no-op otherwise), same pattern used elsewhere in this codebase (e.g. Warehouses."IsActive").
alter table public."ItemWarehouseStockCache" add column if not exists "CategoryCode" text;

create index if not exists "IX_ItemWarehouseStockCache_WarehouseId" on public."ItemWarehouseStockCache" ("WarehouseId");
create index if not exists "IX_ItemWarehouseStockCache_ItemCode" on public."ItemWarehouseStockCache" ("ItemCode");
create index if not exists "IX_ItemWarehouseStockCache_CategoryCode" on public."ItemWarehouseStockCache" ("CategoryCode");

alter table public."ItemWarehouseStockCache" enable row level security;
revoke all on public."ItemWarehouseStockCache" from anon, authenticated;

drop function if exists public.staff_refresh_item_warehouse_stock(text, text);
drop function if exists public.staff_start_item_warehouse_stock_refresh(text, text);

-- Step 1 of 2: truncates the cache and hands back every distinct Pancake product id the client
-- needs to walk. Cheap and instant - no HTTP calls here, just a local query.
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

  truncate public."ItemWarehouseStockCache";

  return query
    select distinct p.product_id::text from (
      select "ProductId" as product_id from public."Items" where "ProductId" is not null and trim("ProductId") <> ''
      union
      select "ProductId" as product_id from public."Variants" where "ProductId" is not null and trim("ProductId") <> ''
    ) p
    order by 1;
end;
$$;

grant execute on function public.staff_start_item_warehouse_stock_refresh(text, text) to anon;

drop function if exists public.staff_refresh_item_warehouse_stock_product(text, text, text);

-- Step 2 of 2: called once per product id from staff_start_item_warehouse_stock_refresh's list -
-- one Pancake HTTP request per call, so no single call can ever approach the statement timeout
-- regardless of how large the catalog grows. Appends rows for just this one product (the cache was
-- already fully truncated by step 1, so no per-call truncate here).
create or replace function public.staff_refresh_item_warehouse_stock_product(
  p_admin_username text,
  p_admin_password text,
  p_product_id text
)
returns table(rows_written int, fetch_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_response extensions.http_response;
  v_body jsonb;
  v_product jsonb;
  v_variations jsonb;
  v_variation jsonb;
  v_warehouses jsonb;
  v_wh_entry jsonb;
  v_variation_id text;
  v_rows_written int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  create temporary table if not exists tmp_wh_stock_rows (
    product_id text,
    variation_id text,
    warehouse_id text,
    remain_quantity numeric
  ) on commit drop;
  truncate tmp_wh_stock_rows;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');

  begin
    select * into v_response from extensions.http_get(
      v_base_url || '/shops/' || v_shop_id || '/products/' || p_product_id || '?api_key=' || v_api_key
    );

    if v_response.status < 200 or v_response.status >= 300 then
      return query select 0, ('Pancake returned HTTP ' || v_response.status)::text;
      return;
    end if;

    v_body := v_response.content::jsonb;
    v_product := case
      when jsonb_typeof(v_body -> 'product') = 'object' then v_body -> 'product'
      when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
      else v_body
    end;

    v_variations := case
      when jsonb_typeof(v_product -> 'variations') = 'array' then v_product -> 'variations'
      else '[]'::jsonb
    end;

    for v_variation in select * from jsonb_array_elements(v_variations)
    loop
      v_variation_id := coalesce(nullif(v_variation ->> 'id', ''), nullif(v_variation ->> 'variation_id', ''));

      v_warehouses := case
        when jsonb_typeof(v_variation -> 'variations_warehouses') = 'array' then v_variation -> 'variations_warehouses'
        else '[]'::jsonb
      end;

      for v_wh_entry in select * from jsonb_array_elements(v_warehouses)
      loop
        insert into tmp_wh_stock_rows values (
          p_product_id,
          v_variation_id,
          coalesce(nullif(v_wh_entry ->> 'warehouse_id', ''), nullif(v_wh_entry ->> 'warehouseId', '')),
          nullif(coalesce(v_wh_entry ->> 'remain_quantity', v_wh_entry ->> 'remainQuantity', v_wh_entry ->> 'quantity'), '')::numeric
        );
      end loop;
    end loop;
  exception when others then
    return query select 0, sqlerrm::text;
    return;
  end;

  -- Resolve each row's real Items.Code via scalar subqueries (each LIMIT 1, so this can never fan
  -- out into duplicate rows even if a ProductId happens to match more than one Items row): prefer
  -- the matching Variant's own ItemCode, falling back to an Items row matched directly by
  -- ProductId for products with no variants.
  insert into public."ItemWarehouseStockCache" ("ProductId", "VariationId", "ItemCode", "ItemName", "CategoryCode", "WarehouseId", "RemainQuantity", "FetchedAtUtc")
  select
    s.product_id,
    s.variation_id,
    rc.resolved_code,
    coalesce(nullif(trim(itm."Name"), ''), nullif(trim(itm."Description"), ''), rc.resolved_code),
    itm."CategoryCode",
    s.warehouse_id,
    s.remain_quantity,
    now()
  from tmp_wh_stock_rows s
  cross join lateral (
    select coalesce(
      (select v."ItemCode" from public."Variants" v where v."VariationId" = s.variation_id limit 1),
      (select i."Code" from public."Items" i where i."ProductId" = s.product_id limit 1)
    ) as resolved_code
  ) rc
  left join public."Items" itm on itm."Code" = rc.resolved_code
  where s.warehouse_id is not null and rc.resolved_code is not null;

  get diagnostics v_rows_written = row_count;

  return query select v_rows_written, null::text;
end;
$$;

grant execute on function public.staff_refresh_item_warehouse_stock_product(text, text, text) to anon;

drop function if exists public.staff_list_item_warehouse_stock(text, text, text, text);
drop function if exists public.staff_list_item_warehouse_stock(text, text, text, text, text);

create or replace function public.staff_list_item_warehouse_stock(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text default null,
  p_search text default null,
  p_category_code text default null
)
returns table(
  item_code text,
  item_name text,
  category_code text,
  category_name text,
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
      c."WarehouseId"::text,
      coalesce(w."Name", c."WarehouseId")::text as warehouse_name,
      c."RemainQuantity",
      (select max("FetchedAtUtc") from public."ItemWarehouseStockCache")
    from public."ItemWarehouseStockCache" c
    left join public."Warehouses" w on w."ID" = c."WarehouseId"
    left join public."Categories" cat on cat."Code" = c."CategoryCode"
    where c."ItemCode" is not null
      and (p_warehouse_id is null or trim(p_warehouse_id) = '' or c."WarehouseId" = p_warehouse_id)
      and (p_category_code is null or trim(p_category_code) = '' or c."CategoryCode" = p_category_code)
      and (
        p_search is null or trim(p_search) = ''
        or c."ItemCode" ilike '%' || trim(p_search) || '%'
        or c."ItemName" ilike '%' || trim(p_search) || '%'
      )
    order by coalesce(nullif(trim(c."ItemName"), ''), c."ItemCode"), warehouse_name;
end;
$$;

grant execute on function public.staff_list_item_warehouse_stock(text, text, text, text, text) to anon;
