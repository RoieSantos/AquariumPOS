-- Stock On Hand - show the variant, not just the resolved item code/name. Per direct request:
-- "in stock on hand i think we should show the variant too".
--
-- staff_refresh_item_warehouse_stock_product (supabase_item_warehouse_stock.sql) already resolves
-- each Pancake variation's stock down to that Variant's own linked Items.Code (falling back to the
-- parent product's code when a variation has no distinct one) - but the cache only ever kept that
-- resolved code's plain Items.Name, so two different variants that both fall back to the same
-- parent code (or simply share a generic product name) were indistinguishable on the report even
-- though they're separate rows with their own quantities. Variants."VariantName" already carries a
-- more specific label synced straight from Pancake ("<resolved code> - <Pancake's own variation
-- name>", see supabase_pancake_manual_sync.sql) - this just carries that same label through onto
-- the cache and the report, exactly like CategoryCode/ItemName already are.
alter table public."ItemWarehouseStockCache" add column if not exists "VariantName" text;

drop function if exists public.staff_refresh_item_warehouse_stock_product(text, text, text);

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
  -- ProductId for products with no variants. VariantName is carried straight from that same
  -- Variants row (already computed at Pancake-sync time), null for products with no variants.
  insert into public."ItemWarehouseStockCache" ("ProductId", "VariationId", "ItemCode", "ItemName", "VariantName", "CategoryCode", "WarehouseId", "RemainQuantity", "FetchedAtUtc")
  select
    s.product_id,
    s.variation_id,
    rc.resolved_code,
    coalesce(nullif(trim(itm."Name"), ''), nullif(trim(itm."Description"), ''), rc.resolved_code),
    rc.variant_name,
    itm."CategoryCode",
    s.warehouse_id,
    s.remain_quantity,
    now()
  from tmp_wh_stock_rows s
  cross join lateral (
    select
      coalesce(
        (select v."ItemCode" from public."Variants" v where v."VariationId" = s.variation_id limit 1),
        (select i."Code" from public."Items" i where i."ProductId" = s.product_id limit 1)
      ) as resolved_code,
      (select v."VariantName" from public."Variants" v where v."VariationId" = s.variation_id limit 1) as variant_name
  ) rc
  left join public."Items" itm on itm."Code" = rc.resolved_code
  where s.warehouse_id is not null and rc.resolved_code is not null;

  get diagnostics v_rows_written = row_count;

  return query select v_rows_written, null::text;
end;
$$;

grant execute on function public.staff_refresh_item_warehouse_stock_product(text, text, text) to anon;

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
  variant_name text,
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
      nullif(trim(c."VariantName"), '')::text,
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
        or c."VariantName" ilike '%' || trim(p_search) || '%'
      )
    order by coalesce(nullif(trim(c."ItemName"), ''), c."ItemCode"), warehouse_name;
end;
$$;

grant execute on function public.staff_list_item_warehouse_stock(text, text, text, text, text, text) to anon;
