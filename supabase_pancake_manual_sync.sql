-- Manual "Sync Now" buttons on the Web Portal's Warehouse Setup / Item Setup pages.
--
-- Unlike OnlinefunctionsEvents.SyncWarehouseAsync()/SyncProductVariationsAsync() (which
-- pull Pancake -> local SQL Server, then the desktop app separately pushes local -> Supabase),
-- these functions call the Pancake (pages.fm) API DIRECTLY from Postgres and write straight into
-- Supabase's Warehouses/Items/Variants tables - no local DB involved, per explicit request. This
-- means these Supabase rows can end up ahead of the local DB until the desktop app's own
-- 5-minute timer catches up (harmless - Pancake remains the single source of truth either way).
--
-- Field mappings intentionally mirror the existing C# methods/tables, so behavior stays
-- consistent whichever path last wrote to a row:
--   Warehouses: id -> ID, name -> Name (IsProductionWarehouse/IsStockWarehouse are local-only
--     flags Pancake doesn't provide, so they are only set on INSERT, default false, and are
--     never overwritten on UPDATE).
--   Items <- GET /products (product-level only): match by SKU first, falling back to Code
--     (display_id/code). Name, Price, CategoryCode, SKU, ProductId (Pancake's own "id"), and
--     Images (best-effort, checks the common image/photo-ish keys Pancake product payloads
--     use) are all touched - Description is set once on INSERT only (= Name), same as the
--     local desktop app's auto-add behavior.
--   Variants <- GET /products/variations: mirrors local dbo.[Variant] - one row per variation
--     keyed by VariationId, linked back to Items via MainItemCode (the parent product's own
--     code) and ItemCode (the actual Items.Code it resolved to, matched by SKU-then-Code -
--     same precedence as Items). Every column dbo.[Variant] has is mapped: SKU, VariantName,
--     Price, CategoryCode, Images (falls back from variation-level to product-level). Pancake
--     genuinely exposes products and their variations as separate endpoints, so this mirrors
--     that split instead of cramming both into "Items".
--   After Variants are resolved, their VariationId/ProductId/Images/CategoryCode/Price are also
--     cross-written back onto the linked Items row (one representative variant per item), same
--     as SyncProductVariationsAsync's byCode/bySku UPDATE statements do locally.
--   Neither endpoint provides Cost, WholesalePrice, RetailPrice, PromoPrice, QuantityInStock,
--   MinimumStock, Brand, IsActive - those are local-only POS fields and are left untouched.
--
-- Requires the "http" extension (bundled/allowed by Supabase, enabled below) to make outbound
-- HTTPS requests synchronously from a plpgsql function.
--
-- TIMEOUT NOTE: "HTTP request cancelled" from the http extension means the underlying curl
-- request was aborted, almost always due to a timeout - either (a) the http extension's own
-- default 5-second curl timeout (too short for Pancake's /products/variations endpoint when
-- asking for up to 10000 rows at once), or (b) PostgREST's connection role (authenticator)
-- hitting its default statement_timeout (commonly ~8s) before a multi-page sync finishes. Both
-- are addressed below: the curl timeout is set per-call via http_set_curlopt(), and the
-- authenticator role's statement_timeout is raised so the whole RPC call is allowed to run
-- longer. The ALTER ROLE only needs to be run once (affects new connections going forward).

create extension if not exists http with schema extensions;

-- Applies to ALL PostgREST/API requests project-wide (not just these two functions) since
-- authenticator is the physical login role PostgREST connects as. 120s is generous headroom
-- for a large product catalog without leaving requests to hang indefinitely.
alter role authenticator set statement_timeout = '120000';

drop function if exists public.admin_sync_warehouses_from_pancake(text, text);

create or replace function public.admin_sync_warehouses_from_pancake(p_admin_username text, p_admin_password text)
returns table(synced_count int, inserted_count int, updated_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_items jsonb;
  v_item jsonb;
  v_id text;
  v_name text;
  v_synced int := 0;
  v_inserted int := 0;
  v_updated int := 0;
  v_was_existing boolean;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Raise the http extension's own per-request curl timeout from its 5s default to 30s.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

  v_url := 'https://pos.pages.fm/api/v1/shops/1328301944/warehouses?api_key=e611861d2fc84607bfbbe1428a432447';
  v_response := extensions.http_get(v_url);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake warehouses request failed (HTTP %).', v_response.status;
  end if;

  v_body := v_response.content::jsonb;

  v_items := case
    when jsonb_typeof(v_body) = 'array' then v_body
    when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'warehouses') = 'array' then v_body -> 'warehouses'
    else '[]'::jsonb
  end;

  for v_item in select * from jsonb_array_elements(v_items)
  loop
    v_id := coalesce(v_item ->> 'id', v_item ->> 'ID');
    if v_id is null or trim(v_id) = '' then
      continue;
    end if;

    v_name := v_item ->> 'name';

    select exists(select 1 from public."Warehouses" where "ID" = v_id) into v_was_existing;

    insert into public."Warehouses" ("ID", "Name", "IsProductionWarehouse", "IsStockWarehouse", "SyncedAtUtc")
    values (v_id, v_name, false, false, now())
    on conflict ("ID") do update
      set "Name" = excluded."Name",
          "SyncedAtUtc" = now();

    v_synced := v_synced + 1;
    if v_was_existing then
      v_updated := v_updated + 1;
    else
      v_inserted := v_inserted + 1;
    end if;
  end loop;

  return query select v_synced, v_inserted, v_updated;
end;
$$;

drop function if exists public.admin_sync_items_from_pancake(text, text);

-- Two-phase sync, mirroring the local desktop app's split between dbo.Items and
-- dbo.[Variant] (see OnlinefunctionsEvents.SyncProductVariationsAsync): Pancake exposes
-- products and their variations as genuinely separate concepts/endpoints, so this
-- function pulls each from its own endpoint into its own Supabase table instead of
-- cramming both into "Items" at once.
--   Phase 1: Items <- GET /shops/{id}/products (product-level: code, name, price, category).
--   Phase 2: Variants <- GET /shops/{id}/products/variations (one row per variation, linked
--     back to Items via MainItemCode/ItemCode - same SKU-then-Code match precedence as before).
create or replace function public.admin_sync_items_from_pancake(p_admin_username text, p_admin_password text)
returns table(
  items_synced int, items_inserted int, items_updated int,
  variants_synced int, variants_inserted int, variants_updated int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_products_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products?api_key=e611861d2fc84607bfbbe1428a432447';
  v_variations_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products/variations?api_key=e611861d2fc84607bfbbe1428a432447';
  v_page int;
  v_max_pages int := 500;
  v_page_size int := 200;
  v_response extensions.http_response;
  v_body jsonb;
  v_page_items jsonb;
  v_items_synced int := 0;
  v_items_inserted int := 0;
  v_items_updated int := 0;
  v_variants_synced int := 0;
  v_variants_inserted int := 0;
  v_variants_updated int := 0;
  v_count int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Raise the http extension's own per-request curl timeout from its 5s default to 45s.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '45000');

  ------------------------------------------------------------------------------------
  -- Phase 1: Items <- /products (product-level fields only - no variation nesting).
  ------------------------------------------------------------------------------------
  create temporary table if not exists tmp_pancake_products (
    code text,
    sku text,
    name text,
    price numeric,
    category text,
    product_id text,
    images text
  ) on commit drop;
  truncate tmp_pancake_products;

  v_page := 1;
  while v_page <= v_max_pages loop
    v_response := extensions.http_get(v_products_url || '&page=' || v_page || '&pagesize=' || v_page_size);

    if v_response.status < 200 or v_response.status >= 300 then
      if v_page = 1 then
        raise exception 'Pancake products request failed (HTTP %).', v_response.status;
      end if;
      exit;
    end if;

    v_body := v_response.content::jsonb;
    v_page_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'products') = 'array' then v_body -> 'products'
      else '[]'::jsonb
    end;

    exit when jsonb_typeof(v_page_items) <> 'array' or jsonb_array_length(v_page_items) = 0;

    -- NOTE on field mapping (confirmed via a live Pancake API call): a bare product object's own
    -- "display_id" is a small NUMERIC per-product sequence number (e.g. 931) - NOT the
    -- human-facing code (e.g. "F-112") used everywhere else in this codebase (desktop
    -- dbo.Items.Code, the Orders sync's product_display_id). That real code instead lives on
    -- the product's "custom_id" field (per explicit request, now the primary source for Code)
    -- and is mirrored on the product's first embedded VARIATION as ITS OWN "display_id" (a
    -- string), used as the first fallback if custom_id is ever blank. Price/Images are likewise
    -- nested inside variations[0], not present on the bare product object at all. Only fall back
    -- to the bare numeric product display_id as an absolute last resort (kept only so a product
    -- with zero usable identifiers still gets some code rather than being dropped).
    insert into tmp_pancake_products (code, sku, name, price, category, product_id, images)
    select
      coalesce(
        nullif(product ->> 'custom_id', ''),
        nullif(product -> 'variations' -> 0 ->> 'display_id', ''),
        nullif(product ->> 'code', ''),
        nullif(product ->> 'sku', ''),
        nullif(product ->> 'display_id', ''),
        product ->> 'id'
      ) as code,
      -- SKU per explicit request: Pancake has no field literally called "sku" anywhere in either
      -- /products or /products/variations (confirmed via live API calls) - the closest real
      -- field is display_id (the human-facing code, e.g. "F-112"), so SKU is sourced from that
      -- instead. This intentionally mirrors Code's own display_id fallback - SKU and Code will
      -- often end up equal, which is the requested behavior, not a bug.
      coalesce(nullif(product -> 'variations' -> 0 ->> 'display_id', ''), nullif(product ->> 'display_id', '')) as sku,
      product ->> 'name' as name,
      public.try_parse_numeric(coalesce(
        nullif(product -> 'variations' -> 0 ->> 'retail_price', ''),
        nullif(product ->> 'retail_price', ''),
        product ->> 'price'
      )) as price,
      public.try_extract_first_category(product) as category,
      nullif(product ->> 'id', '') as product_id,
      coalesce(public.try_extract_first_image(product -> 'variations' -> 0), public.try_extract_first_image(product)) as images
    from jsonb_array_elements(v_page_items) as product
    where coalesce(
      nullif(product ->> 'custom_id', ''),
      nullif(product -> 'variations' -> 0 ->> 'display_id', ''),
      nullif(product ->> 'code', ''),
      nullif(product ->> 'sku', ''),
      nullif(product ->> 'display_id', ''),
      product ->> 'id'
    ) is not null;

    -- BUGFIX: Pancake silently caps /products and /products/variations at a fixed page_size
    -- of 30 regardless of the pagesize requested here (confirmed via a live test - even
    -- pagesize=1000 still came back capped at 30 items, total_entries/total_pages in the
    -- response confirm it) - unlike /orders, which genuinely honors its own page_size param.
    -- The old "exit when this page is shorter than the REQUESTED page_size" check was therefore
    -- always true on page 1 (30 < 200), so this loop silently only ever synced the first ~30
    -- products/variations and never advanced to page 2+. The only reliable "reached the end"
    -- signal is an EMPTY page.
    exit when jsonb_array_length(v_page_items) = 0;
    v_page := v_page + 1;
  end loop;

  -- Resolve which existing Items row (if any) each staged product belongs to: prefer a
  -- SKU match, falling back to a direct Code match.
  create temporary table if not exists tmp_pancake_products_resolved (
    code text,
    sku text,
    name text,
    price numeric,
    category text,
    product_id text,
    images text,
    was_existing boolean
  ) on commit drop;
  truncate tmp_pancake_products_resolved;

  insert into tmp_pancake_products_resolved (code, sku, name, price, category, product_id, images, was_existing)
  select distinct on (coalesce(existing.matched_code, t.code))
    coalesce(existing.matched_code, t.code) as code,
    t.sku, t.name, t.price, t.category, t.product_id, t.images,
    (existing.matched_code is not null) as was_existing
  from tmp_pancake_products t
  left join lateral (
    select i."Code" as matched_code
    from public."Items" i
    where (t.sku is not null and i."SKU" = t.sku) or i."Code" = t.code
    order by (i."SKU" = t.sku) desc nulls last
    limit 1
  ) existing on true
  order by coalesce(existing.matched_code, t.code);

  with upd as (
    update public."Items" i
    set "Name" = coalesce(nullif(r.name, ''), i."Name"),
        "Price" = coalesce(r.price, i."Price"),
        "CategoryCode" = coalesce(r.category, i."CategoryCode"),
        "SKU" = coalesce(r.sku, i."SKU"),
        "ProductId" = coalesce(nullif(r.product_id, ''), i."ProductId"),
        "Images" = coalesce(nullif(r.images, ''), i."Images"),
        "SyncedAtUtc" = now()
    from tmp_pancake_products_resolved r
    where r.was_existing and i."Code" = r.code
    returning i."Code"
  )
  select count(*) into v_count from upd;
  v_items_updated := v_count;

  with ins as (
    insert into public."Items" ("Code", "Name", "Description", "Price", "CategoryCode", "SKU", "ProductId", "Images", "SyncedAtUtc")
    select r.code, r.name, r.name, r.price, r.category, r.sku, r.product_id, r.images, now()
    from tmp_pancake_products_resolved r
    where not r.was_existing
    returning 1
  )
  select count(*) into v_count from ins;
  v_items_inserted := v_count;

  select count(*) into v_items_synced from tmp_pancake_products_resolved;

  ------------------------------------------------------------------------------------
  -- Phase 2: Variants <- /products/variations (one row per variation, linked back to
  -- the Items row it belongs to - same SKU-then-Code match precedence as Phase 1).
  ------------------------------------------------------------------------------------
  create temporary table if not exists tmp_pancake_variants (
    variation_id text,
    main_item_code text,
    sku text,
    name text,
    price numeric,
    category text,
    product_id text,
    images text
  ) on commit drop;
  truncate tmp_pancake_variants;

  v_page := 1;
  while v_page <= v_max_pages loop
    v_response := extensions.http_get(v_variations_url || '&page=' || v_page || '&pagesize=' || v_page_size);

    if v_response.status < 200 or v_response.status >= 300 then
      if v_page = 1 then
        raise exception 'Pancake products/variations request failed (HTTP %).', v_response.status;
      end if;
      exit;
    end if;

    v_body := v_response.content::jsonb;
    v_page_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'variations') = 'array' then v_body -> 'variations'
      else '[]'::jsonb
    end;

    exit when jsonb_typeof(v_page_items) <> 'array' or jsonb_array_length(v_page_items) = 0;

    insert into tmp_pancake_variants (variation_id, main_item_code, sku, name, price, category, product_id, images)
    select
      f.variation_id, f.main_item_code, f.sku, f.name, f.price, f.category, f.product_id, f.images
    from (
      -- Here "variation" IS the correct level for the human-facing code - its own "display_id"
      -- is the real string code (e.g. "F-112"), unlike the parent product's numeric one.
      select
        coalesce(variation ->> 'variation_id', variation ->> 'id') as variation_id,
        coalesce(
          nullif(variation ->> 'display_id', ''),
          nullif(product ->> 'custom_id', ''),
          nullif(product ->> 'code', ''),
          nullif(product ->> 'sku', ''),
          nullif(product ->> 'display_id', ''),
          variation ->> 'id'
        ) as main_item_code,
        -- SKU sourced from display_id, not a "sku" field - see the Phase 1 note above.
        nullif(coalesce(variation ->> 'display_id', product ->> 'display_id'), '') as sku,
        coalesce(nullif(variation ->> 'name', ''), product ->> 'name') as name,
        public.try_parse_numeric(coalesce(nullif(variation ->> 'retail_price', ''), nullif(variation ->> 'price', ''), nullif(product ->> 'retail_price', ''), product ->> 'price')) as price,
        public.try_extract_first_category(product) as category,
        nullif(coalesce(variation ->> 'product_id', product ->> 'id'), '') as product_id,
        coalesce(public.try_extract_first_image(variation), public.try_extract_first_image(product)) as images
      from jsonb_array_elements(v_page_items) as product,
           jsonb_array_elements(product -> 'variations') as variation
      where jsonb_typeof(product -> 'variations') = 'array' and jsonb_array_length(product -> 'variations') > 0

      union all

      -- Fallback for a flat/no-nested-variations row shape - THIS is the branch every real
      -- /products/variations row actually takes (confirmed via a live API call: that endpoint
      -- returns one flat object per variation with a NESTED "product" sub-object holding the
      -- parent product's own name/categories - it never nests a "variations" array the way the
      -- branch above assumes). "product" here is the SQL loop variable bound to that flat
      -- variation-level element, so its own display_id (if present) is the right code - but its
      -- name/categories are NOT top-level on this element, they're one level down at
      -- product.product.name / product.product.categories. Reading product->>'name'/
      -- try_extract_first_category(product) directly (as before) always returned null here,
      -- silently leaving VariantName/CategoryCode without the real product name/category for
      -- every synced variant. coalesce keeps a top-level fallback in case some other product
      -- shape ever does put name/categories at this level directly.
      select
        coalesce(product ->> 'variation_id', product ->> 'id') as variation_id,
        coalesce(
          nullif(product ->> 'display_id', ''),
          nullif(product ->> 'custom_id', ''),
          nullif(product ->> 'code', ''),
          nullif(product ->> 'sku', ''),
          product ->> 'id'
        ) as main_item_code,
        -- SKU sourced from display_id, not a "sku" field - see the Phase 1 note above.
        nullif(product ->> 'display_id', '') as sku,
        coalesce(nullif(product -> 'product' ->> 'name', ''), nullif(product ->> 'name', '')) as name,
        public.try_parse_numeric(coalesce(nullif(product ->> 'retail_price', ''), product ->> 'price')) as price,
        coalesce(public.try_extract_first_category(product -> 'product'), public.try_extract_first_category(product)) as category,
        nullif(coalesce(product ->> 'product_id', product ->> 'id'), '') as product_id,
        public.try_extract_first_image(product) as images
      from jsonb_array_elements(v_page_items) as product
      where coalesce(jsonb_typeof(product -> 'variations'), 'null') <> 'array' or jsonb_array_length(product -> 'variations') = 0
    ) f
    where f.variation_id is not null and trim(f.variation_id) <> '';

    -- BUGFIX: Pancake silently caps /products and /products/variations at a fixed page_size
    -- of 30 regardless of the pagesize requested here (confirmed via a live test - even
    -- pagesize=1000 still came back capped at 30 items, total_entries/total_pages in the
    -- response confirm it) - unlike /orders, which genuinely honors its own page_size param.
    -- The old "exit when this page is shorter than the REQUESTED page_size" check was therefore
    -- always true on page 1 (30 < 200), so this loop silently only ever synced the first ~30
    -- products/variations and never advanced to page 2+. The only reliable "reached the end"
    -- signal is an EMPTY page.
    exit when jsonb_array_length(v_page_items) = 0;
    v_page := v_page + 1;
  end loop;

  create temporary table if not exists tmp_pancake_variants_resolved (
    variation_id text,
    main_item_code text,
    item_code text,
    sku text,
    name text,
    price numeric,
    category text,
    product_id text,
    images text,
    was_existing boolean
  ) on commit drop;
  truncate tmp_pancake_variants_resolved;

  insert into tmp_pancake_variants_resolved (variation_id, main_item_code, item_code, sku, name, price, category, product_id, images, was_existing)
  select distinct on (t.variation_id)
    t.variation_id,
    coalesce(existing.matched_code, t.main_item_code, t.variation_id) as main_item_code,
    existing.matched_code as item_code,
    t.sku, t.name, t.price, t.category, t.product_id, t.images,
    exists(select 1 from public."Variants" v where v."VariationId" = t.variation_id) as was_existing
  from tmp_pancake_variants t
  -- ProductId is now the primary link between a Variant and its Items row (Pancake's own
  -- stable id, exact-match - not a fuzzy SKU/Code guess): by the time Phase 2 runs, Phase 1
  -- has already written this same product_id onto Items."ProductId" for every synced product,
  -- so it's reliably available here. SKU-then-Code stays as a fallback for variants whose
  -- product_id didn't resolve (or for older Items rows synced before ProductId was persisted),
  -- same "never drop a fallback, just reorder priority" approach used elsewhere in this file.
  left join lateral (
    select i."Code" as matched_code
    from public."Items" i
    where (t.product_id is not null and i."ProductId" = t.product_id)
       or (t.sku is not null and i."SKU" = t.sku)
       or i."Code" = t.main_item_code
    order by
      (i."ProductId" = t.product_id) desc nulls last,
      (i."SKU" = t.sku) desc nulls last
    limit 1
  ) existing on true
  order by t.variation_id;

  -- VariantName per "Variant name (SKU) should be ItemCode + Product name" / "update/map the
  -- Variant Name on Variants table" - persisted here at sync time (not just computed for
  -- display) as "<the resolved Items.Code, or MainItemCode if unresolved> - <Pancake's product
  -- name>", instead of storing Pancake's raw per-variation name (often blank or a plain SKU
  -- copy).
  insert into public."Variants" ("VariationId", "MainItemCode", "ItemCode", "SKU", "VariantName", "Price", "CategoryCode", "Images", "ProductId", "SyncedAtUtc")
  select
    r.variation_id, r.main_item_code, r.item_code, r.sku,
    case
      when r.name is not null and trim(r.name) <> ''
      then coalesce(r.item_code, r.main_item_code) || ' - ' || r.name
      else coalesce(r.item_code, r.main_item_code)
    end,
    r.price, r.category, r.images, nullif(r.product_id, ''), now()
  from tmp_pancake_variants_resolved r
  on conflict ("VariationId") do update
    set "MainItemCode" = excluded."MainItemCode",
        "ItemCode" = excluded."ItemCode",
        "SKU" = excluded."SKU",
        "VariantName" = excluded."VariantName",
        "Price" = excluded."Price",
        "CategoryCode" = excluded."CategoryCode",
        "Images" = coalesce(excluded."Images", public."Variants"."Images"),
        "ProductId" = coalesce(excluded."ProductId", public."Variants"."ProductId"),
        "SyncedAtUtc" = now();

  select count(*) filter (where was_existing), count(*) filter (where not was_existing), count(*)
    into v_variants_updated, v_variants_inserted, v_variants_synced
  from tmp_pancake_variants_resolved;

  -- Cross-link back onto Items, same as the local desktop app's SyncProductVariationsAsync
  -- (its byCode/bySku UPDATE statements): the resolved VariationId/ProductId/Images/
  -- CategoryCode/Price of one representative variant per linked item are written onto that
  -- Items row too, so Items.VariationId/ProductId/Images stay populated even though those
  -- fields don't come from the /products endpoint itself.
  with variant_item_link as (
    select distinct on (item_code)
      item_code, variation_id, product_id, images, category, price
    from tmp_pancake_variants_resolved
    where item_code is not null
    order by item_code, variation_id desc
  )
  update public."Items" i
  set "VariationId" = coalesce(l.variation_id, i."VariationId"),
      "ProductId" = coalesce(nullif(l.product_id, ''), i."ProductId"),
      "Images" = coalesce(nullif(l.images, ''), i."Images"),
      "CategoryCode" = coalesce(nullif(l.category, ''), i."CategoryCode"),
      "Price" = coalesce(l.price, i."Price")
  from variant_item_link l
  where i."Code" = l.item_code;

  return query select v_items_synced, v_items_inserted, v_items_updated, v_variants_synced, v_variants_inserted, v_variants_updated;
end;
$$;

-- Small helper: Pancake sometimes returns numeric-looking fields as JSON strings; this
-- tolerates either shape and returns null instead of raising on genuinely invalid input.
drop function if exists public.try_parse_numeric(text);

create or replace function public.try_parse_numeric(p_value text)
returns numeric
language plpgsql
immutable
as $$
begin
  if p_value is null or trim(p_value) = '' then
    return null;
  end if;
  return p_value::numeric;
exception when others then
  return null;
end;
$$;

-- Small helper mirroring C#'s ExtractFirstImageReference: Pancake product/variation payloads
-- don't have one consistent image field, so this recursively checks the common image-ish keys
-- (and unwraps arrays/nested objects) and returns the first plain string value it finds.
drop function if exists public.try_extract_first_image(jsonb);

create or replace function public.try_extract_first_image(p_node jsonb)
returns text
language plpgsql
immutable
as $$
declare
  v_kind text;
  v_elem jsonb;
  v_key text;
  v_found text;
begin
  if p_node is null then
    return null;
  end if;

  v_kind := jsonb_typeof(p_node);

  if v_kind = 'string' then
    return nullif(p_node #>> '{}', '');
  end if;

  if v_kind = 'array' then
    for v_elem in select * from jsonb_array_elements(p_node) loop
      v_found := public.try_extract_first_image(v_elem);
      if v_found is not null and trim(v_found) <> '' then
        return trim(v_found);
      end if;
    end loop;
    return null;
  end if;

  if v_kind = 'object' then
    foreach v_key in array array['images', 'image', 'image_url', 'imageUrl', 'thumbnail', 'thumbnail_url', 'photo', 'photos', 'url', 'src']
    loop
      if p_node ? v_key then
        v_found := public.try_extract_first_image(p_node -> v_key);
        if v_found is not null and trim(v_found) <> '' then
          return trim(v_found);
        end if;
      end if;
    end loop;
    return null;
  end if;

  return null;
exception when others then
  return null;
end;
$$;

-- Small helper: Pancake's /products payload exposes a product's category as a "categories"
-- ARRAY of {id, name} objects (confirmed via a live API call - a single product can technically
-- carry more than one), not the flat "category" string field earlier versions of this file
-- assumed. Returns the first category's name, or null if there are none.
drop function if exists public.try_extract_first_category(jsonb);

create or replace function public.try_extract_first_category(p_node jsonb)
returns text
language sql
immutable
as $$
  select c ->> 'name'
  from jsonb_array_elements(coalesce(p_node -> 'categories', '[]'::jsonb)) as c
  limit 1;
$$;

grant execute on function public.admin_sync_warehouses_from_pancake(text, text) to anon;
grant execute on function public.admin_sync_items_from_pancake(text, text) to anon;

-- ============================================================================
-- LIVE Items view - per "can you show all the items available and sync it the
-- way we are syncing the orders": mirrors admin_list_online_orders_live's
-- pattern instead of requiring the "Sync Now" button to be clicked first.
-- Fetches exactly ONE Pancake /products page per call (same single-page-per-
-- call reasoning as that function - looping several pages inside one call
-- risks the API gateway's own "HTTP request cancelled" abort, a different and
-- uncatchable failure mode from a plain Postgres statement timeout), and the
-- portal (itemSetup.js) loops CLIENT-SIDE, one RPC call per page, appending
-- rows as they arrive and stopping once has_more is false or a page comes back
-- empty.
--
-- AUTOMATIC PERSISTENCE: every product fetched for live display is also
-- upserted into public."Items" (product-level fields only, same SKU-then-Code
-- match precedence as admin_sync_items_from_pancake) regardless of the
-- caller's search filter - so simply browsing the Items page keeps Supabase
-- fresh without needing the deep "Sync Now" button to have run first. Cost/
-- WholesalePrice/RetailPrice/PromoPrice/QuantityInStock/MinimumStock/Brand/
-- IsActive are local-only POS fields Pancake doesn't provide, so (matching
-- admin_sync_items_from_pancake) they are only set on INSERT and never
-- touched on UPDATE. Variants are intentionally NOT synced here - that needs
-- a second Pancake endpoint call per page, which stays covered by the
-- deep/manual "Sync Now" button (admin_sync_items_from_pancake) only, same
-- asymmetry as Online Orders' lines (only the manual "Sync from Pancake"
-- button fills those in, not the live per-page view).
drop function if exists public.admin_list_items_live(text, text, text, int, int);

create or replace function public.admin_list_items_live(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 100
)
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
  synced_at_utc timestamptz,
  has_more boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_products_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products?api_key=e611861d2fc84607bfbbe1428a432447';
  v_page_size int := least(greatest(coalesce(p_page_size, 100), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_response extensions.http_response;
  v_body jsonb;
  v_page_items jsonb;
  v_product jsonb;
  v_first_variation jsonb;
  v_has_more boolean;
  v_row_count int := 0;
  v_code text;
  v_sku text;
  v_name text;
  v_price numeric;
  v_category text;
  v_product_id text;
  v_images text;
  v_matched_code text;
  v_matches_search boolean;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

  v_response := extensions.http_get(v_products_url || '&page=' || v_page || '&pagesize=' || v_page_size);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake products request failed (HTTP %).', v_response.status;
  end if;

  v_body := v_response.content::jsonb;
  v_page_items := case
    when jsonb_typeof(v_body) = 'array' then v_body
    when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'products') = 'array' then v_body -> 'products'
    else '[]'::jsonb
  end;

  -- BUGFIX: same fix as cron_sync_items_from_pancake above - Pancake caps /products at a fixed
  -- page_size of 30 regardless of the pagesize requested, so comparing this page's length to
  -- the REQUESTED v_page_size made has_more always false (30 never >= 100). "More to fetch" now
  -- just means "this page returned something" - the client keeps calling until an empty page.
  v_has_more := jsonb_typeof(v_page_items) = 'array' and jsonb_array_length(v_page_items) > 0;

  for v_product in select * from jsonb_array_elements(v_page_items)
  loop
    begin
      -- Same field-mapping fix as admin_sync_items_from_pancake/cron_sync_items_from_pancake -
      -- the real code/price/images live on the product's first embedded variation, not on the
      -- bare product object; category is a "categories" array, not a flat string. See the note
      -- in tmp_pancake_products' insert above for the full explanation.
      v_first_variation := case
        when jsonb_typeof(v_product -> 'variations') = 'array' and jsonb_array_length(v_product -> 'variations') > 0
        then v_product -> 'variations' -> 0
        else null
      end;

      v_code := coalesce(
        nullif(v_product ->> 'custom_id', ''),
        nullif(v_first_variation ->> 'display_id', ''),
        nullif(v_product ->> 'code', ''),
        nullif(v_product ->> 'sku', ''),
        nullif(v_product ->> 'display_id', ''),
        v_product ->> 'id'
      );
      if v_code is null or trim(v_code) = '' then
        continue;
      end if;

      -- SKU sourced from display_id, not a "sku" field - see the Phase 1 note in
      -- tmp_pancake_products' insert above.
      v_sku := coalesce(nullif(v_first_variation ->> 'display_id', ''), nullif(v_product ->> 'display_id', ''));
      v_name := v_product ->> 'name';
      v_price := public.try_parse_numeric(coalesce(nullif(v_first_variation ->> 'retail_price', ''), nullif(v_product ->> 'retail_price', ''), v_product ->> 'price'));
      v_category := public.try_extract_first_category(v_product);
      v_product_id := nullif(v_product ->> 'id', '');
      v_images := coalesce(public.try_extract_first_image(v_first_variation), public.try_extract_first_image(v_product));

      -- Resolve which existing Items row this product belongs to (SKU match first, then Code) -
      -- same precedence as admin_sync_items_from_pancake, so a live browse and a full "Sync Now"
      -- both land on the same row instead of accidentally creating duplicates.
      select i."Code" into v_matched_code
      from public."Items" i
      where (v_sku is not null and i."SKU" = v_sku) or i."Code" = v_code
      order by (i."SKU" = v_sku) desc nulls last
      limit 1;

      begin
        if v_matched_code is not null then
          update public."Items"
            set "Name" = coalesce(nullif(v_name, ''), "Name"),
                "Price" = coalesce(v_price, "Price"),
                "CategoryCode" = coalesce(v_category, "CategoryCode"),
                "SKU" = coalesce(v_sku, "SKU"),
                "ProductId" = coalesce(v_product_id, "ProductId"),
                "Images" = coalesce(nullif(v_images, ''), "Images"),
                "SyncedAtUtc" = now()
            where "Code" = v_matched_code;
        else
          insert into public."Items" ("Code", "Name", "Description", "Price", "CategoryCode", "SKU", "ProductId", "Images", "SyncedAtUtc")
          values (v_code, v_name, v_name, v_price, v_category, v_sku, v_product_id, v_images, now())
          on conflict ("Code") do update set
            "Name" = coalesce(nullif(excluded."Name", ''), public."Items"."Name"),
            "Price" = coalesce(excluded."Price", public."Items"."Price"),
            "CategoryCode" = coalesce(excluded."CategoryCode", public."Items"."CategoryCode"),
            "SKU" = coalesce(excluded."SKU", public."Items"."SKU"),
            "ProductId" = coalesce(excluded."ProductId", public."Items"."ProductId"),
            "Images" = coalesce(nullif(excluded."Images", ''), public."Items"."Images"),
            "SyncedAtUtc" = now();
          v_matched_code := v_code;
        end if;
      exception when others then
        null; -- persistence is best-effort - never let it block showing the live row
      end;

      v_matches_search := p_search is null or trim(p_search) = '' or v_matched_code ilike '%' || p_search || '%' or v_name ilike '%' || p_search || '%';
      if not v_matches_search then
        continue;
      end if;

      v_row_count := v_row_count + 1;

      select i."Code", i."Name", i."Description", i."Cost", i."Price", i."WholesalePrice", i."RetailPrice", i."PromoPrice",
             i."CategoryCode", i."Brand", i."SKU", i."QuantityInStock", i."MinimumStock", i."IsActive", i."SyncedAtUtc"
        into code, name, description, cost, price, wholesale_price, retail_price, promo_price,
             category_code, brand, sku, quantity_in_stock, minimum_stock, is_active, synced_at_utc
      from public."Items" i
      where i."Code" = v_matched_code;

      has_more := v_has_more;
      return next;
    exception when others then
      null; -- skip malformed product row, keep processing the rest
    end;
  end loop;

  -- If every item on this page got filtered out client-side (search mismatch), still emit one
  -- sentinel row so the client learns has_more without seeing a false "no items" result. The
  -- client treats code IS NULL as "not a real item, just a has_more signal" and skips it.
  if v_row_count = 0 then
    code := null;
    name := null;
    description := null;
    cost := null;
    price := null;
    wholesale_price := null;
    retail_price := null;
    promo_price := null;
    category_code := null;
    brand := null;
    sku := null;
    quantity_in_stock := null;
    minimum_stock := null;
    is_active := null;
    synced_at_utc := null;
    has_more := v_has_more;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_list_items_live(text, text, text, int, int) to anon;

-- ============================================================================
-- Cron sync for Items/Products - per "the online orders has been syncing over to
-- supabase via cron, can you do for Items/Products too?": keeps public."Items"/
-- "Variants" fresh independent of whether the desktop app (and its own 5-minute
-- masterDataSyncTimer push) happens to be running, same resilience Online Orders
-- already gets from cron_sync_online_orders_from_pancake below.
--
-- Unlike Online Orders, there's no incremental/delta sync here - Pancake's
-- Products/Variations endpoints don't support an updated_after-style filter (the
-- desktop C# code and admin_sync_items_from_pancake above both just page through
-- the full catalog every time), so this is a full paged re-pull on every run, not
-- a PancakeSyncState-tracked cursor. Scheduled every 5 minutes rather than every
-- minute (like Online Orders) since a full-catalog pull is heavier than an
-- incremental page of order changes, and product/category data changes far less
-- often than order status - this cadence also matches the desktop app's own
-- masterDataSyncTimer, making this cron job a background-independent backstop
-- for exactly what that timer already does.
--
-- This is admin_sync_items_from_pancake's body verbatim, with two changes: (1)
-- no p_admin_username/p_admin_password/is_admin_authorized check, since pg_cron
-- calls this directly inside Postgres, never through PostgREST/the anon key
-- (same reasoning as cron_sync_online_orders_from_pancake below - and likewise
-- never granted to anon); (2) v_max_pages/v_page_size are function parameters
-- instead of hardcoded declares, so the schedule below (or a manual test call)
-- can tune them without editing the function body.
drop function if exists public.cron_sync_items_from_pancake(int, int);

create or replace function public.cron_sync_items_from_pancake(p_max_pages int default 500, p_page_size int default 200)
returns table(
  items_synced int, items_inserted int, items_updated int,
  variants_synced int, variants_inserted int, variants_updated int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_products_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products?api_key=e611861d2fc84607bfbbe1428a432447';
  v_variations_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products/variations?api_key=e611861d2fc84607bfbbe1428a432447';
  v_page int;
  v_max_pages int := least(greatest(coalesce(p_max_pages, 500), 1), 500);
  v_page_size int := least(greatest(coalesce(p_page_size, 200), 1), 200);
  v_response extensions.http_response;
  v_body jsonb;
  v_page_items jsonb;
  v_items_synced int := 0;
  v_items_inserted int := 0;
  v_items_updated int := 0;
  v_variants_synced int := 0;
  v_variants_inserted int := 0;
  v_variants_updated int := 0;
  v_count int;
begin
  -- Raise the http extension's own per-request curl timeout from its 5s default to 45s.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '45000');

  ------------------------------------------------------------------------------------
  -- Phase 1: Items <- /products (product-level fields only - no variation nesting).
  ------------------------------------------------------------------------------------
  create temporary table if not exists tmp_pancake_products (
    code text,
    sku text,
    name text,
    price numeric,
    category text,
    product_id text,
    images text
  ) on commit drop;
  truncate tmp_pancake_products;

  v_page := 1;
  while v_page <= v_max_pages loop
    v_response := extensions.http_get(v_products_url || '&page=' || v_page || '&pagesize=' || v_page_size);

    if v_response.status < 200 or v_response.status >= 300 then
      if v_page = 1 then
        raise exception 'Pancake products request failed (HTTP %).', v_response.status;
      end if;
      exit;
    end if;

    v_body := v_response.content::jsonb;
    v_page_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'products') = 'array' then v_body -> 'products'
      else '[]'::jsonb
    end;

    exit when jsonb_typeof(v_page_items) <> 'array' or jsonb_array_length(v_page_items) = 0;

    -- NOTE on field mapping (confirmed via a live Pancake API call): a bare product object's own
    -- "display_id" is a small NUMERIC per-product sequence number (e.g. 931) - NOT the
    -- human-facing code (e.g. "F-112") used everywhere else in this codebase (desktop
    -- dbo.Items.Code, the Orders sync's product_display_id). That real code instead lives on
    -- the product's "custom_id" field (per explicit request, now the primary source for Code)
    -- and is mirrored on the product's first embedded VARIATION as ITS OWN "display_id" (a
    -- string), used as the first fallback if custom_id is ever blank. Price/Images are likewise
    -- nested inside variations[0], not present on the bare product object at all. Only fall back
    -- to the bare numeric product display_id as an absolute last resort (kept only so a product
    -- with zero usable identifiers still gets some code rather than being dropped).
    insert into tmp_pancake_products (code, sku, name, price, category, product_id, images)
    select
      coalesce(
        nullif(product ->> 'custom_id', ''),
        nullif(product -> 'variations' -> 0 ->> 'display_id', ''),
        nullif(product ->> 'code', ''),
        nullif(product ->> 'sku', ''),
        nullif(product ->> 'display_id', ''),
        product ->> 'id'
      ) as code,
      -- SKU per explicit request: Pancake has no field literally called "sku" anywhere in either
      -- /products or /products/variations (confirmed via live API calls) - the closest real
      -- field is display_id (the human-facing code, e.g. "F-112"), so SKU is sourced from that
      -- instead. This intentionally mirrors Code's own display_id fallback - SKU and Code will
      -- often end up equal, which is the requested behavior, not a bug.
      coalesce(nullif(product -> 'variations' -> 0 ->> 'display_id', ''), nullif(product ->> 'display_id', '')) as sku,
      product ->> 'name' as name,
      public.try_parse_numeric(coalesce(
        nullif(product -> 'variations' -> 0 ->> 'retail_price', ''),
        nullif(product ->> 'retail_price', ''),
        product ->> 'price'
      )) as price,
      public.try_extract_first_category(product) as category,
      nullif(product ->> 'id', '') as product_id,
      coalesce(public.try_extract_first_image(product -> 'variations' -> 0), public.try_extract_first_image(product)) as images
    from jsonb_array_elements(v_page_items) as product
    where coalesce(
      nullif(product ->> 'custom_id', ''),
      nullif(product -> 'variations' -> 0 ->> 'display_id', ''),
      nullif(product ->> 'code', ''),
      nullif(product ->> 'sku', ''),
      nullif(product ->> 'display_id', ''),
      product ->> 'id'
    ) is not null;

    -- BUGFIX: Pancake silently caps /products and /products/variations at a fixed page_size
    -- of 30 regardless of the pagesize requested here (confirmed via a live test - even
    -- pagesize=1000 still came back capped at 30 items, total_entries/total_pages in the
    -- response confirm it) - unlike /orders, which genuinely honors its own page_size param.
    -- The old "exit when this page is shorter than the REQUESTED page_size" check was therefore
    -- always true on page 1 (30 < 200), so this loop silently only ever synced the first ~30
    -- products/variations and never advanced to page 2+. The only reliable "reached the end"
    -- signal is an EMPTY page.
    exit when jsonb_array_length(v_page_items) = 0;
    v_page := v_page + 1;
  end loop;

  -- Resolve which existing Items row (if any) each staged product belongs to: prefer a
  -- SKU match, falling back to a direct Code match.
  create temporary table if not exists tmp_pancake_products_resolved (
    code text,
    sku text,
    name text,
    price numeric,
    category text,
    product_id text,
    images text,
    was_existing boolean
  ) on commit drop;
  truncate tmp_pancake_products_resolved;

  insert into tmp_pancake_products_resolved (code, sku, name, price, category, product_id, images, was_existing)
  select distinct on (coalesce(existing.matched_code, t.code))
    coalesce(existing.matched_code, t.code) as code,
    t.sku, t.name, t.price, t.category, t.product_id, t.images,
    (existing.matched_code is not null) as was_existing
  from tmp_pancake_products t
  left join lateral (
    select i."Code" as matched_code
    from public."Items" i
    where (t.sku is not null and i."SKU" = t.sku) or i."Code" = t.code
    order by (i."SKU" = t.sku) desc nulls last
    limit 1
  ) existing on true
  order by coalesce(existing.matched_code, t.code);

  with upd as (
    update public."Items" i
    set "Name" = coalesce(nullif(r.name, ''), i."Name"),
        "Price" = coalesce(r.price, i."Price"),
        "CategoryCode" = coalesce(r.category, i."CategoryCode"),
        "SKU" = coalesce(r.sku, i."SKU"),
        "ProductId" = coalesce(nullif(r.product_id, ''), i."ProductId"),
        "Images" = coalesce(nullif(r.images, ''), i."Images"),
        "SyncedAtUtc" = now()
    from tmp_pancake_products_resolved r
    where r.was_existing and i."Code" = r.code
    returning i."Code"
  )
  select count(*) into v_count from upd;
  v_items_updated := v_count;

  with ins as (
    insert into public."Items" ("Code", "Name", "Description", "Price", "CategoryCode", "SKU", "ProductId", "Images", "SyncedAtUtc")
    select r.code, r.name, r.name, r.price, r.category, r.sku, r.product_id, r.images, now()
    from tmp_pancake_products_resolved r
    where not r.was_existing
    returning 1
  )
  select count(*) into v_count from ins;
  v_items_inserted := v_count;

  select count(*) into v_items_synced from tmp_pancake_products_resolved;

  ------------------------------------------------------------------------------------
  -- Phase 2: Variants <- /products/variations (one row per variation, linked back to
  -- the Items row it belongs to - same SKU-then-Code match precedence as Phase 1).
  ------------------------------------------------------------------------------------
  create temporary table if not exists tmp_pancake_variants (
    variation_id text,
    main_item_code text,
    sku text,
    name text,
    price numeric,
    category text,
    product_id text,
    images text
  ) on commit drop;
  truncate tmp_pancake_variants;

  v_page := 1;
  while v_page <= v_max_pages loop
    v_response := extensions.http_get(v_variations_url || '&page=' || v_page || '&pagesize=' || v_page_size);

    if v_response.status < 200 or v_response.status >= 300 then
      if v_page = 1 then
        raise exception 'Pancake products/variations request failed (HTTP %).', v_response.status;
      end if;
      exit;
    end if;

    v_body := v_response.content::jsonb;
    v_page_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'variations') = 'array' then v_body -> 'variations'
      else '[]'::jsonb
    end;

    exit when jsonb_typeof(v_page_items) <> 'array' or jsonb_array_length(v_page_items) = 0;

    insert into tmp_pancake_variants (variation_id, main_item_code, sku, name, price, category, product_id, images)
    select
      f.variation_id, f.main_item_code, f.sku, f.name, f.price, f.category, f.product_id, f.images
    from (
      -- Here "variation" IS the correct level for the human-facing code - its own "display_id"
      -- is the real string code (e.g. "F-112"), unlike the parent product's numeric one.
      select
        coalesce(variation ->> 'variation_id', variation ->> 'id') as variation_id,
        coalesce(
          nullif(variation ->> 'display_id', ''),
          nullif(product ->> 'custom_id', ''),
          nullif(product ->> 'code', ''),
          nullif(product ->> 'sku', ''),
          nullif(product ->> 'display_id', ''),
          variation ->> 'id'
        ) as main_item_code,
        -- SKU sourced from display_id, not a "sku" field - see the Phase 1 note above.
        nullif(coalesce(variation ->> 'display_id', product ->> 'display_id'), '') as sku,
        coalesce(nullif(variation ->> 'name', ''), product ->> 'name') as name,
        public.try_parse_numeric(coalesce(nullif(variation ->> 'retail_price', ''), nullif(variation ->> 'price', ''), nullif(product ->> 'retail_price', ''), product ->> 'price')) as price,
        public.try_extract_first_category(product) as category,
        nullif(coalesce(variation ->> 'product_id', product ->> 'id'), '') as product_id,
        coalesce(public.try_extract_first_image(variation), public.try_extract_first_image(product)) as images
      from jsonb_array_elements(v_page_items) as product,
           jsonb_array_elements(product -> 'variations') as variation
      where jsonb_typeof(product -> 'variations') = 'array' and jsonb_array_length(product -> 'variations') > 0

      union all

      -- Fallback for a flat/no-nested-variations row shape - THIS is the branch every real
      -- /products/variations row actually takes (confirmed via a live API call: that endpoint
      -- returns one flat object per variation with a NESTED "product" sub-object holding the
      -- parent product's own name/categories - it never nests a "variations" array the way the
      -- branch above assumes). "product" here is the SQL loop variable bound to that flat
      -- variation-level element, so its own display_id (if present) is the right code - but its
      -- name/categories are NOT top-level on this element, they're one level down at
      -- product.product.name / product.product.categories. Reading product->>'name'/
      -- try_extract_first_category(product) directly (as before) always returned null here,
      -- silently leaving VariantName/CategoryCode without the real product name/category for
      -- every synced variant. coalesce keeps a top-level fallback in case some other product
      -- shape ever does put name/categories at this level directly.
      select
        coalesce(product ->> 'variation_id', product ->> 'id') as variation_id,
        coalesce(
          nullif(product ->> 'display_id', ''),
          nullif(product ->> 'custom_id', ''),
          nullif(product ->> 'code', ''),
          nullif(product ->> 'sku', ''),
          product ->> 'id'
        ) as main_item_code,
        -- SKU sourced from display_id, not a "sku" field - see the Phase 1 note above.
        nullif(product ->> 'display_id', '') as sku,
        coalesce(nullif(product -> 'product' ->> 'name', ''), nullif(product ->> 'name', '')) as name,
        public.try_parse_numeric(coalesce(nullif(product ->> 'retail_price', ''), product ->> 'price')) as price,
        coalesce(public.try_extract_first_category(product -> 'product'), public.try_extract_first_category(product)) as category,
        nullif(coalesce(product ->> 'product_id', product ->> 'id'), '') as product_id,
        public.try_extract_first_image(product) as images
      from jsonb_array_elements(v_page_items) as product
      where coalesce(jsonb_typeof(product -> 'variations'), 'null') <> 'array' or jsonb_array_length(product -> 'variations') = 0
    ) f
    where f.variation_id is not null and trim(f.variation_id) <> '';

    -- BUGFIX: Pancake silently caps /products and /products/variations at a fixed page_size
    -- of 30 regardless of the pagesize requested here (confirmed via a live test - even
    -- pagesize=1000 still came back capped at 30 items, total_entries/total_pages in the
    -- response confirm it) - unlike /orders, which genuinely honors its own page_size param.
    -- The old "exit when this page is shorter than the REQUESTED page_size" check was therefore
    -- always true on page 1 (30 < 200), so this loop silently only ever synced the first ~30
    -- products/variations and never advanced to page 2+. The only reliable "reached the end"
    -- signal is an EMPTY page.
    exit when jsonb_array_length(v_page_items) = 0;
    v_page := v_page + 1;
  end loop;

  create temporary table if not exists tmp_pancake_variants_resolved (
    variation_id text,
    main_item_code text,
    item_code text,
    sku text,
    name text,
    price numeric,
    category text,
    product_id text,
    images text,
    was_existing boolean
  ) on commit drop;
  truncate tmp_pancake_variants_resolved;

  insert into tmp_pancake_variants_resolved (variation_id, main_item_code, item_code, sku, name, price, category, product_id, images, was_existing)
  select distinct on (t.variation_id)
    t.variation_id,
    coalesce(existing.matched_code, t.main_item_code, t.variation_id) as main_item_code,
    existing.matched_code as item_code,
    t.sku, t.name, t.price, t.category, t.product_id, t.images,
    exists(select 1 from public."Variants" v where v."VariationId" = t.variation_id) as was_existing
  from tmp_pancake_variants t
  -- ProductId is now the primary link between a Variant and its Items row (Pancake's own
  -- stable id, exact-match - not a fuzzy SKU/Code guess): by the time Phase 2 runs, Phase 1
  -- has already written this same product_id onto Items."ProductId" for every synced product,
  -- so it's reliably available here. SKU-then-Code stays as a fallback for variants whose
  -- product_id didn't resolve (or for older Items rows synced before ProductId was persisted),
  -- same "never drop a fallback, just reorder priority" approach used elsewhere in this file.
  left join lateral (
    select i."Code" as matched_code
    from public."Items" i
    where (t.product_id is not null and i."ProductId" = t.product_id)
       or (t.sku is not null and i."SKU" = t.sku)
       or i."Code" = t.main_item_code
    order by
      (i."ProductId" = t.product_id) desc nulls last,
      (i."SKU" = t.sku) desc nulls last
    limit 1
  ) existing on true
  order by t.variation_id;

  -- VariantName per "Variant name (SKU) should be ItemCode + Product name" / "update/map the
  -- Variant Name on Variants table" - persisted here at sync time (not just computed for
  -- display) as "<the resolved Items.Code, or MainItemCode if unresolved> - <Pancake's product
  -- name>", instead of storing Pancake's raw per-variation name (often blank or a plain SKU
  -- copy).
  insert into public."Variants" ("VariationId", "MainItemCode", "ItemCode", "SKU", "VariantName", "Price", "CategoryCode", "Images", "ProductId", "SyncedAtUtc")
  select
    r.variation_id, r.main_item_code, r.item_code, r.sku,
    case
      when r.name is not null and trim(r.name) <> ''
      then coalesce(r.item_code, r.main_item_code) || ' - ' || r.name
      else coalesce(r.item_code, r.main_item_code)
    end,
    r.price, r.category, r.images, nullif(r.product_id, ''), now()
  from tmp_pancake_variants_resolved r
  on conflict ("VariationId") do update
    set "MainItemCode" = excluded."MainItemCode",
        "ItemCode" = excluded."ItemCode",
        "SKU" = excluded."SKU",
        "VariantName" = excluded."VariantName",
        "Price" = excluded."Price",
        "CategoryCode" = excluded."CategoryCode",
        "Images" = coalesce(excluded."Images", public."Variants"."Images"),
        "ProductId" = coalesce(excluded."ProductId", public."Variants"."ProductId"),
        "SyncedAtUtc" = now();

  select count(*) filter (where was_existing), count(*) filter (where not was_existing), count(*)
    into v_variants_updated, v_variants_inserted, v_variants_synced
  from tmp_pancake_variants_resolved;

  -- Cross-link back onto Items, same as the local desktop app's SyncProductVariationsAsync
  -- (its byCode/bySku UPDATE statements): the resolved VariationId/ProductId/Images/
  -- CategoryCode/Price of one representative variant per linked item are written onto that
  -- Items row too, so Items.VariationId/ProductId/Images stay populated even though those
  -- fields don't come from the /products endpoint itself.
  with variant_item_link as (
    select distinct on (item_code)
      item_code, variation_id, product_id, images, category, price
    from tmp_pancake_variants_resolved
    where item_code is not null
    order by item_code, variation_id desc
  )
  update public."Items" i
  set "VariationId" = coalesce(l.variation_id, i."VariationId"),
      "ProductId" = coalesce(nullif(l.product_id, ''), i."ProductId"),
      "Images" = coalesce(nullif(l.images, ''), i."Images"),
      "CategoryCode" = coalesce(nullif(l.category, ''), i."CategoryCode"),
      "Price" = coalesce(l.price, i."Price")
  from variant_item_link l
  where i."Code" = l.item_code;

  -- Bookkeeping only - NOT a delta cursor like PancakeSyncState('/orders'). Pancake's
  -- /products and /variations endpoints silently ignore an updated_after filter (confirmed
  -- via a live test against both), so this run was still a full re-pull regardless of this
  -- timestamp. Recording it here just lets "when did Items last finish syncing" be checked
  -- the same way Orders freshness is checked, via one shared table.
  insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
  values ('/products', now())
  on conflict ("Entity") do update set "LastSyncUtc" = excluded."LastSyncUtc";

  return query select v_items_synced, v_items_inserted, v_items_updated, v_variants_synced, v_variants_inserted, v_variants_updated;
end;
$$;

-- No grant to anon - called directly by pg_cron inside Postgres, never through PostgREST.

do $$
begin
  perform cron.unschedule('sync-items-from-pancake');
exception when others then
  null; -- job didn't exist yet - nothing to unschedule
end;
$$;

select cron.schedule(
  'sync-items-from-pancake',
  '*/5 * * * *',
  $$select public.cron_sync_items_from_pancake();$$
);

-- ============================================================================
-- Online Orders: direct Pancake -> Supabase sync ("Sync Now" button on the Web
-- Portal's Online Orders page). Added because relying solely on the desktop
-- app's own push (OnlinefunctionsEvents.SyncOnlineOrdersToSupabaseAsync, local
-- SQL Server -> Supabase) means the portal only reflects fresh Pancake data
-- whenever the desktop POS happens to be running. This talks to Pancake
-- directly from Postgres instead - same "channel 3" pattern as Warehouses/
-- Items above (http extension, security definer, no local DB involved).
--
-- Does NOT apply to Advance Orders - those are created in-store only and have
-- no Pancake equivalent, so they can only ever come from the desktop app.
--
-- Field mapping mirrors IntegrationEvents.SyncOrderListAsync (order list) and
-- IntegrationEvents.FetchOrderLinesAsync/WriteintoOnlineOrderLines (order
-- lines) as closely as SQL allows: same field-name fallback chains, same
-- status normalization (submitted->Confirmed, packing/packed->To Ship, etc),
-- same "only sync orders where received_at_shop = 'false'" filter, same "skip
-- status = New" filter, same UTC -> Asia/Manila (business UTC+8) date/time
-- conversion, same GrossAmount = Price*Quantity with Discount/NetAmount/
-- UnitCost left untouched for lines (Pancake doesn't supply them).
--
-- Safety caps: order LINES require one extra HTTP call per order (an N+1
-- pattern the local desktop app can get away with since it isn't bound by
-- PostgREST's statement_timeout). Defaults to 5 pages x 100 orders/page = 500
-- orders per click, tracked incrementally via PancakeSyncState so repeat
-- clicks only re-fetch orders updated since the last successful run (mirrors
-- the local dbo.OnlineOrderSync last-sync-timestamp behavior). Click "Sync
-- Now" again for a large historical backlog - each click resumes roughly
-- where the last one left off since headers are upserted immediately.

alter role authenticator set statement_timeout = '300000';

-- Generic "last sync" cursor table (per "I want a new table named Last Sync table... entity :
-- '/orders', Last Date sync : ..."): one row per Pancake API entity/endpoint synced, rather than
-- being hardcoded to just orders (the old PancakeOrderSyncState, keyed only by ShopId) - future
-- entities (e.g. '/products') can reuse this same table/pattern without a new table each time.
create table if not exists public."PancakeSyncState" (
  "Entity" text primary key,
  "LastSyncUtc" timestamptz
);

alter table public."PancakeSyncState" enable row level security;
revoke all on public."PancakeSyncState" from anon, authenticated;

-- One-time migration from the old orders-only table - safe to re-run since this whole file gets
-- re-run wholesale on every deploy: only does anything the first time, when the old table still
-- exists, then drops it so later re-runs are no-ops.
do $$
begin
  if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'PancakeOrderSyncState') then
    insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
    select '/orders', "LastSyncUtc" from public."PancakeOrderSyncState" where "ShopId" = '1328301944'
    on conflict ("Entity") do nothing;

    drop table public."PancakeOrderSyncState";
  end if;
end;
$$;

create or replace function public.pancake_try_parse_timestamptz(p_raw text)
returns timestamptz
language plpgsql
as $$
begin
  if p_raw is null or trim(p_raw) = '' then
    return null;
  end if;
  return p_raw::timestamptz;
exception when others then
  return null;
end;
$$;

create or replace function public.pancake_parse_decimal(p_raw text)
returns numeric
language plpgsql
as $$
declare
  v_cleaned text;
begin
  if p_raw is null or trim(p_raw) = '' then
    return 0;
  end if;
  v_cleaned := regexp_replace(p_raw, '[^0-9\.\-]', '', 'g');
  if v_cleaned = '' or v_cleaned = '-' then
    return 0;
  end if;
  return v_cleaned::numeric;
exception when others then
  return 0;
end;
$$;

-- Who/when created/confirmed the order, per Pancake's own status_history array on that order
-- (each entry has a numeric "status" and a "name" - status 0 = order created, status 1 = order
-- confirmed). Shared by all three Pancake-order-sync functions below (admin_sync_online_orders_
-- from_pancake, cron_sync_online_orders_from_pancake, admin_list_online_orders_live) so this
-- logic lives in exactly one place. Purely for reporting (see CreatedBy/ConfirmedBy/ConfirmedAtUtc
-- columns on public."OnlineOrders" in supabase_orders_sync_tables.sql) - nothing here is
-- enforced/gated. Deliberately entirely Supabase-side (calls Pancake directly via
-- extensions.http_get, same as the rest of this file) - the desktop POS is not involved in
-- populating these at all.
--
-- confirmed_at: the status=1 entry's own timestamp, for the Order Confirmation Timing dashboard.
-- The exact key Pancake uses per status_history entry isn't documented anywhere in this codebase,
-- so this tries every plausible candidate (same defensive-coalesce style already used for the
-- order-level created/updated timestamps just below in this file) via
-- public.pancake_try_parse_timestamptz() - stays null, harmlessly, if none of them match a given
-- entry's actual shape.
--
-- Explicit DROP first: this function's return signature is widening (added confirmed_at), and
-- Postgres refuses a CREATE OR REPLACE that changes a function's OUT-parameter/return-table shape
-- (42P13 "cannot change return type of existing function") - unlike every other signature change
-- in this file, this one never had a drop guard because its shape never changed until now.
drop function if exists public.pancake_extract_created_confirmed_by(jsonb);

create or replace function public.pancake_extract_created_confirmed_by(p_item jsonb)
returns table(created_by text, confirmed_by text, confirmed_at timestamptz)
language plpgsql
as $$
declare
  v_status_history jsonb;
  v_entry jsonb;
  v_status_code int;
  v_created_by text := null;
  v_confirmed_by text := null;
  v_confirmed_at timestamptz := null;
  v_confirmed_at_raw text;
begin
  v_status_history := p_item -> 'status_history';
  if jsonb_typeof(v_status_history) = 'array' then
    for v_entry in select * from jsonb_array_elements(v_status_history)
    loop
      v_status_code := null;
      begin
        v_status_code := nullif(trim(v_entry ->> 'status'), '')::int;
      exception when others then
        v_status_code := null;
      end;

      if v_status_code = 0 and v_created_by is null then
        v_created_by := v_entry ->> 'name';
      elsif v_status_code = 1 and v_confirmed_by is null then
        v_confirmed_by := v_entry ->> 'name';
        v_confirmed_at_raw := coalesce(
          v_entry ->> 'inserted_at', v_entry ->> 'insertedAt', v_entry ->> 'created_at', v_entry ->> 'createdAt',
          v_entry ->> 'updated_at', v_entry ->> 'updatedAt', v_entry ->> 'time', v_entry ->> 'at', v_entry ->> 'date'
        );
        v_confirmed_at := public.pancake_try_parse_timestamptz(v_confirmed_at_raw);
      end if;
    end loop;
  end if;

  return query select v_created_by, v_confirmed_by, v_confirmed_at;
end;
$$;

drop function if exists public.admin_sync_online_orders_from_pancake(text, text, int, int);

create or replace function public.admin_sync_online_orders_from_pancake(
  p_admin_username text,
  p_admin_password text,
  p_max_pages int default 5,
  p_page_size int default 100
)
returns table(orders_synced int, orders_inserted int, orders_updated int, lines_synced int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := 'e611861d2fc84607bfbbe1428a432447';
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_page_size int := least(greatest(coalesce(p_page_size, 100), 1), 200);
  v_max_pages int := least(greatest(coalesce(p_max_pages, 5), 1), 50);
  v_last_sync_utc timestamptz;
  v_since_qs text := '';
  v_iso text;
  v_page int;
  v_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_items jsonb;
  v_item jsonb;
  v_items_this_page int;
  v_order_id text;
  v_rec_flag text;
  v_received_at_shop boolean;
  v_status_raw text;
  v_status text;
  v_customer text;
  v_created_raw text;
  v_created_utc timestamptz;
  v_date date;
  v_time text;
  v_page_id text;
  v_conversation_id text;
  v_location_id text;
  v_money_raw text;
  v_money_to_collect numeric;
  v_prepaid_raw text;
  v_amount_paid numeric;
  v_cod_raw text;
  v_balance numeric;
  v_discount_raw text;
  v_discount numeric;
  v_last_paid_raw text;
  v_last_paid_utc timestamptz;
  v_last_paid_date date;
  v_last_paid_time text;
  v_last_updated_raw text;
  v_last_updated_utc timestamptz;
  v_converted_last_updated_date date;
  v_for_delivery_kind text;
  v_for_delivery boolean;
  v_shipping_address text;
  v_est_delivery_raw text;
  v_est_delivery_date date;
  v_created_by text;
  v_confirmed_by text;
  v_confirmed_at timestamptz;
  v_was_existing boolean;
  v_orders_synced int := 0;
  v_orders_inserted int := 0;
  v_orders_updated int := 0;
  v_lines_synced int := 0;
  v_max_run_utc timestamptz := now();
  -- Order lines (detail fetch per order)
  v_detail_url text;
  v_detail_response extensions.http_response;
  v_detail_body jsonb;
  v_order_el jsonb;
  v_line_items jsonb;
  v_line_item jsonb;
  v_variation_info jsonb;
  v_product_display_id text;
  v_variation_id text;
  v_qty numeric;
  v_price numeric;
  v_line_name text;
  v_line_note text;
  v_line_id text;
  -- Glass thickness detection (per-order, reset before each order's line-item loop) - this
  -- function already pays for a full per-order detail fetch to get lines, so persisting the
  -- glass flag here too is free; see the GlassThickness column comment in
  -- supabase_orders_sync_tables.sql for the full detection/caching design.
  v_glass_has_12mm boolean;
  v_glass_has_10mm boolean;
  v_glass_thickness text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  select "LastSyncUtc" into v_last_sync_utc from public."PancakeSyncState" where "Entity" = '/orders';

  if v_last_sync_utc is not null then
    v_iso := to_char(v_last_sync_utc at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    v_since_qs := '&updated_after=' || v_iso || '&updatedAfter=' || v_iso
      || '&created_after=' || v_iso || '&createdAfter=' || v_iso || '&since=' || v_iso;
  end if;

  for v_page in 1..v_max_pages loop
    v_url := v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key
      || '&page_size=' || v_page_size || '&page=' || v_page || v_since_qs;

    v_response := extensions.http_get(v_url);
    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake orders request failed (HTTP %) on page %.', v_response.status, v_page;
    end if;

    v_body := v_response.content::jsonb;

    v_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'orders') = 'array' then v_body -> 'orders'
      else '[]'::jsonb
    end;

    v_items_this_page := jsonb_array_length(v_items);
    exit when v_items_this_page = 0;

    for v_item in select * from jsonb_array_elements(v_items)
    loop
      begin
        v_rec_flag := coalesce(v_item ->> 'received_at_shop', v_item ->> 'receivedAtShop');
        v_received_at_shop := lower(coalesce(trim(v_rec_flag), '')) = 'true';
        if lower(coalesce(trim(v_rec_flag), '')) not in ('true', 'false') then
          continue;
        end if;

        v_order_id := coalesce(
          v_item ->> 'receipt_no', v_item ->> 'receiptNo', v_item ->> 'receipt',
          v_item ->> 'id', v_item ->> 'order_number', v_item ->> 'number'
        );
        if v_order_id is null or trim(v_order_id) = '' then
          continue;
        end if;

        v_status_raw := coalesce(v_item ->> 'status_name', v_item ->> 'status', v_item ->> 'state', v_item ->> 'order_status');
        if lower(trim(coalesce(v_status_raw, ''))) = 'new' then
          continue;
        end if;

        v_last_updated_raw := coalesce(v_item ->> 'updated_at', v_item ->> 'updatedAt', v_item ->> 'last_updated_at', v_item ->> 'lastUpdatedAt');
        v_last_updated_utc := public.pancake_try_parse_timestamptz(v_last_updated_raw);

        if v_last_sync_utc is not null and v_last_updated_utc is not null and v_last_updated_utc <= v_last_sync_utc then
          continue;
        end if;

        v_status := case lower(trim(v_status_raw))
          when 'submitted' then 'Confirmed'
          when 'packing' then 'To Ship'
          when 'packed' then 'To Ship'
          when 'pending' then 'Pending Transfer'
          when '9' then 'Pending Transfer'
          when 'pending_transfer' then 'Pending Transfer'
          when 'pending transfer' then 'Pending Transfer'
          when 'waiting_for_pickup' then 'Pending Transfer'
          when 'waiting for pickup' then 'Pending Transfer'
          when '12' then 'In-Transit'
          when 'wait_print' then 'In-Transit'
          when 'wait print' then 'In-Transit'
          when 'in_transit' then 'In-Transit'
          when 'in-transit' then 'In-Transit'
          when 'shipped' then 'Shipped'
          when 'delivered' then 'Shipped'
          when '2' then 'Shipped'
          when 'received' then 'Received'
          when '3' then 'Received'
          when 'printed' then 'Printed'
          else v_status_raw
        end;

        v_customer := coalesce(
          v_item -> 'customer' ->> 'name', v_item -> 'customer' ->> 'customer_name', v_item -> 'customer' ->> 'full_name',
          v_item ->> 'customer_name', v_item ->> 'customer', v_item ->> 'client_name', v_item ->> 'buyer_name'
        );

        v_created_raw := coalesce(v_item ->> 'inserted_at', v_item ->> 'insertedAt', v_item ->> 'created_at', v_item ->> 'createdAt', v_item ->> 'date', v_item ->> 'created');
        v_created_utc := public.pancake_try_parse_timestamptz(v_created_raw);
        if v_created_utc is not null then
          v_date := (v_created_utc at time zone 'Asia/Manila')::date;
          v_time := to_char(v_created_utc at time zone 'Asia/Manila', 'HH24:MI:SS');
        else
          v_date := null;
          v_time := null;
        end if;

        v_page_id := coalesce(v_item ->> 'page_id', v_item ->> 'pageId', v_item ->> 'page');
        v_conversation_id := coalesce(v_item ->> 'conversation_id', v_item ->> 'conversationId', v_item ->> 'conversation', v_item ->> 'thread_id', v_item ->> 'threadId');
        v_location_id := coalesce(v_item ->> 'warehouse_id', v_item ->> 'warehouseId');

        v_money_raw := coalesce(
          v_item -> 'money_to_collect' ->> 'amount', v_item -> 'money_to_collect' ->> 'value', v_item -> 'money_to_collect' ->> 'total',
          v_item ->> 'money_to_collect', v_item ->> 'moneyToCollect', v_item ->> 'total_price', v_item ->> 'total', v_item ->> 'amount', v_item ->> 'money'
        );
        v_money_to_collect := public.pancake_parse_decimal(v_money_raw);

        v_prepaid_raw := coalesce(
          v_item -> 'prepaid' ->> 'amount', v_item -> 'prepaid' ->> 'value',
          v_item ->> 'prepaid', v_item ->> 'prepaid_amount', v_item ->> 'pre_paid', v_item ->> 'deposit', v_item ->> 'prepayment'
        );
        v_amount_paid := public.pancake_parse_decimal(v_prepaid_raw);

        v_cod_raw := coalesce(
          v_item -> 'cod' ->> 'amount', v_item -> 'cod' ->> 'value',
          v_item ->> 'cod', v_item ->> 'cash_on_delivery', v_item ->> 'balance', v_item ->> 'due', v_item ->> 'amount_due'
        );
        v_balance := public.pancake_parse_decimal(v_cod_raw);

        v_discount_raw := coalesce(v_item ->> 'discount', v_item ->> 'discount_amount', v_item ->> 'discounted_amount');
        v_discount := public.pancake_parse_decimal(v_discount_raw);

        v_last_paid_raw := coalesce(v_item ->> 'last_paid_at', v_item ->> 'lastPaidAt', v_item ->> 'last_payment', v_item ->> 'last_paid', v_item ->> 'last_payment_at');
        v_last_paid_utc := public.pancake_try_parse_timestamptz(v_last_paid_raw);
        if v_last_paid_utc is not null then
          v_last_paid_date := (v_last_paid_utc at time zone 'Asia/Manila')::date;
          v_last_paid_time := to_char(v_last_paid_utc at time zone 'Asia/Manila', 'HH24:MI:SS');
        elsif v_amount_paid > 0 and v_date is not null then
          v_last_paid_date := v_date;
          v_last_paid_time := v_time;
        else
          v_last_paid_date := null;
          v_last_paid_time := null;
        end if;

        v_converted_last_updated_date := case when v_last_updated_utc is not null then (v_last_updated_utc at time zone 'Asia/Manila')::date else null end;

        v_for_delivery_kind := jsonb_typeof(v_item -> 'is_free_shipping');
        v_for_delivery := case v_for_delivery_kind
          when 'boolean' then (v_item ->> 'is_free_shipping')::boolean
          when 'number' then (v_item ->> 'is_free_shipping')::numeric <> 0
          when 'string' then lower(trim(v_item ->> 'is_free_shipping')) in ('true', 'yes', 'y', 'on', '1')
          else false
        end;

        v_shipping_address := coalesce(
          v_item -> 'shipping_address' ->> 'full_address', v_item -> 'shipping_address' ->> 'fullAddress',
          v_item -> 'shipping_address' ->> 'address', v_item -> 'shipping_address' ->> 'formatted_address', v_item -> 'shipping_address' ->> 'formattedAddress',
          v_item ->> 'shipping_address_full', v_item ->> 'shippingAddressFull', v_item ->> 'full_address', v_item ->> 'fullAddress'
        );

        v_est_delivery_raw := coalesce(
          v_item -> 'estimate_delivery_date' ->> 'new', v_item ->> 'estimate_delivery_date',
          v_item -> 'estimated_delivery_date' ->> 'new', v_item ->> 'estimated_delivery_date',
          v_item ->> 'estimatedDeliveryDate', v_item ->> 'delivery_date', v_item ->> 'deliveryDate'
        );
        v_est_delivery_date := case
          when v_est_delivery_raw is null then null
          when v_est_delivery_raw ~ '^\d{4}-\d{2}-\d{2}$' then v_est_delivery_raw::date
          else (public.pancake_try_parse_timestamptz(v_est_delivery_raw) at time zone 'Asia/Manila')::date
        end;

        select t.created_by, t.confirmed_by, t.confirmed_at into v_created_by, v_confirmed_by, v_confirmed_at
        from public.pancake_extract_created_confirmed_by(v_item) t;

        select exists(select 1 from public."OnlineOrders" where "OrderID" = v_order_id) into v_was_existing;

        insert into public."OnlineOrders" (
          "OrderID", "Date", "Time", "Status", "CustomerName", "Page_ID", "Conversation_ID", "LocationID",
          "MoneyToCollect", "AmountPaid", "Discount", "Balance", "ForDelivery", "ShippingAddress",
          "EstimatedDeliveryDate", "Last_Updated_At", "Converted_LastUpdated_At", "LastPaid_Date", "LastPaid_Time", "ReceivedAtShop",
          "CreatedBy", "ConfirmedBy", "ConfirmedAtUtc", "SyncedAtUtc"
        ) values (
          v_order_id, v_date, v_time, v_status, v_customer, v_page_id, v_conversation_id, v_location_id,
          v_money_to_collect, v_amount_paid, v_discount, v_balance, v_for_delivery, v_shipping_address,
          v_est_delivery_date, v_last_updated_utc, v_converted_last_updated_date, v_last_paid_date, v_last_paid_time, v_received_at_shop,
          v_created_by, v_confirmed_by, v_confirmed_at, now()
        )
        on conflict ("OrderID") do update set
          "Date" = excluded."Date",
          "Time" = excluded."Time",
          "Status" = excluded."Status",
          "CustomerName" = excluded."CustomerName",
          "Page_ID" = excluded."Page_ID",
          "Conversation_ID" = excluded."Conversation_ID",
          "LocationID" = excluded."LocationID",
          "MoneyToCollect" = excluded."MoneyToCollect",
          "AmountPaid" = excluded."AmountPaid",
          "Discount" = excluded."Discount",
          "Balance" = excluded."Balance",
          "ForDelivery" = excluded."ForDelivery",
          "ShippingAddress" = excluded."ShippingAddress",
          "EstimatedDeliveryDate" = excluded."EstimatedDeliveryDate",
          "Last_Updated_At" = excluded."Last_Updated_At",
          "Converted_LastUpdated_At" = excluded."Converted_LastUpdated_At",
          "LastPaid_Date" = excluded."LastPaid_Date",
          "LastPaid_Time" = excluded."LastPaid_Time",
          "ReceivedAtShop" = excluded."ReceivedAtShop",
          "CreatedBy" = coalesce(excluded."CreatedBy", "OnlineOrders"."CreatedBy"),
          "ConfirmedBy" = coalesce(excluded."ConfirmedBy", "OnlineOrders"."ConfirmedBy"),
          "ConfirmedAtUtc" = coalesce(excluded."ConfirmedAtUtc", "OnlineOrders"."ConfirmedAtUtc"),
          "SyncedAtUtc" = now();

        v_orders_synced := v_orders_synced + 1;
        if v_was_existing then
          v_orders_updated := v_orders_updated + 1;
        else
          v_orders_inserted := v_orders_inserted + 1;
        end if;

        -- Order lines: one extra HTTP call per order (mirrors IntegrationEvents.FetchOrderLinesAsync).
        begin
          v_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order_id || '?api_key=' || v_api_key || '&page_size=1000';
          v_detail_response := extensions.http_get(v_detail_url);

          if v_detail_response.status >= 200 and v_detail_response.status < 300 then
            v_detail_body := v_detail_response.content::jsonb;
            v_order_el := case
              when jsonb_typeof(v_detail_body -> 'data') = 'object' then v_detail_body -> 'data'
              when jsonb_typeof(v_detail_body) = 'object' then v_detail_body
              else null
            end;
            v_line_items := case
              when v_order_el is not null and jsonb_typeof(v_order_el -> 'items') = 'array' then v_order_el -> 'items'
              else '[]'::jsonb
            end;
            v_glass_has_12mm := false;
            v_glass_has_10mm := false;

            for v_line_item in select * from jsonb_array_elements(v_line_items)
            loop
              begin
                v_variation_info := v_line_item -> 'variation_info';
                v_product_display_id := coalesce(v_variation_info ->> 'product_display_id', v_line_item ->> 'product_display_id');
                if v_product_display_id is null or trim(v_product_display_id) = '' then
                  continue;
                end if;

                v_variation_id := coalesce(v_variation_info ->> 'variation_id', v_line_item ->> 'variation_id', v_line_item ->> 'variationId');
                v_qty := public.pancake_parse_decimal(v_line_item ->> 'quantity');
                v_price := public.pancake_parse_decimal(coalesce(v_variation_info ->> 'retail_price', v_line_item ->> 'retail_price'));
                v_line_name := coalesce(v_variation_info ->> 'name', v_line_item ->> 'name');
                v_line_note := v_line_item ->> 'note';
                v_line_id := coalesce(
                  v_line_item ->> 'line_id', v_line_item ->> 'id', v_line_item ->> 'order_line_id',
                  v_line_item ->> 'order_item_id', v_line_item ->> 'item_id', ''
                );

                if regexp_replace(coalesce(v_line_name, '') || ' ' || coalesce(v_line_note, '') || ' ' || coalesce(v_product_display_id, ''), '\s+', '', 'g') ilike '%12mm%' then
                  v_glass_has_12mm := true;
                elsif regexp_replace(coalesce(v_line_name, '') || ' ' || coalesce(v_line_note, '') || ' ' || coalesce(v_product_display_id, ''), '\s+', '', 'g') ilike '%10mm%' then
                  v_glass_has_10mm := true;
                end if;

                insert into public."OnlineOrderLines" (
                  "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "GrossAmount", "Note", "Description", "SyncedAtUtc"
                ) values (
                  v_order_id, v_line_id, v_product_display_id, v_product_display_id, nullif(v_variation_id, ''), v_qty, null, v_price, v_price * v_qty, nullif(v_line_note, ''), nullif(v_line_name, ''), now()
                )
                on conflict ("OrderID", "LineID") do update set
                  "ItemCode" = excluded."ItemCode",
                  "product_display_id" = excluded."product_display_id",
                  "VariationId" = excluded."VariationId",
                  "Quantity" = excluded."Quantity",
                  "Price" = excluded."Price",
                  "GrossAmount" = excluded."GrossAmount",
                  "Note" = excluded."Note",
                  "Description" = excluded."Description",
                  "SyncedAtUtc" = now();

                v_lines_synced := v_lines_synced + 1;
              exception when others then
                null; -- skip malformed line, keep processing the rest
              end;
            end loop;

            v_glass_thickness := case when v_glass_has_12mm then '12mm' when v_glass_has_10mm then '10mm' else null end;
            update public."OnlineOrders"
              set "GlassThickness" = v_glass_thickness, "GlassThicknessCheckedAt" = now()
              where "OrderID" = v_order_id;
          end if;
        exception when others then
          null; -- order detail fetch failed/timed out - header is still synced, lines will retry next click
        end;

      exception when others then
        null; -- skip malformed order, keep processing the rest
      end;
    end loop;

    exit when v_items_this_page < v_page_size;
  end loop;

  insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
  values ('/orders', v_max_run_utc)
  on conflict ("Entity") do update set "LastSyncUtc" = excluded."LastSyncUtc";

  return query select v_orders_synced, v_orders_inserted, v_orders_updated, v_lines_synced;
end;
$$;

grant execute on function public.admin_sync_online_orders_from_pancake(text, text, int, int) to anon;

-- ============================================================================
-- BACKGROUND CRON SYNC (per "can we create a timer trigger/cron schedule in
-- Supabase?"): runs entirely inside Postgres via the pg_cron extension, so
-- OnlineOrders/PancakeSyncState stay fresh every 5 minutes on their own,
-- regardless of whether any staff member happens to be browsing the portal
-- (the incremental catch-up added to admin_list_online_orders_live only ever
-- runs when someone loads that page) or whether the desktop app is running.
--
-- NOT exposed to the portal/anon key (no grant to anon below, unlike every
-- other function in this file) - pg_cron executes scheduled jobs directly
-- inside the database as a trusted internal caller, not through PostgREST,
-- so it doesn't go through - and doesn't need - the is_admin_authorized()
-- check the anon-facing admin_sync_online_orders_from_pancake uses to gate
-- the same underlying sync from the web. Keeping this ungranted means it
-- can never be invoked from the web portal even by accident.
--
-- HEADERS ONLY (no order lines): mirrors admin_list_online_orders_live's
-- persistence (fast, page-based, one Pancake call per page) rather than
-- admin_sync_online_orders_from_pancake's heavier N+1 detail-per-order lines
-- fetch - running every 5 minutes with the N+1 pattern would multiply
-- Pancake calls quickly. Lines stay covered by admin_get_online_order_detail_
-- live (fetched on demand when a staff member opens an order) and by the
-- manual "Sync from Pancake" button for the persisted copy.
--
-- Reuses the SAME PancakeSyncState ('/orders') cursor as both the manual
-- sync button and the live view's incremental catch-up - whichever of the
-- three last successfully caught Supabase up with Pancake advances it. The
-- cursor only advances once this run's page walk reaches its true end (an
-- empty page, or a page with fewer than p_page_size items) - if the
-- p_max_pages safety cap is hit first, the cursor is left alone so the next
-- 5-minute run picks up the remaining backlog with the same starting point.
--
-- GLASS THICKNESS BACKFILL (per "how can we populate that glass automatically upon loading
-- the page of online orders"): after the headers-only pass above, this also does up to
-- p_max_glass_detail_calls (default 30) one-off detail fetches - one extra Pancake call each -
-- for whichever synced orders still have "GlassThicknessCheckedAt" is null, i.e. have never
-- been checked. The result (10mm/12mm/null) is cached PERMANENTLY on OnlineOrders and never
-- re-checked once set, same "compute once, cache forever" pattern the desktop app already uses
-- for OnlineOrderHeader's Estimated Delivery Date (see DetectPriorityGlassThickness in
-- OnlineOrdersForm.cs). The cap keeps a single run cheap and bounded even though the initial
-- backlog (thousands of pre-existing orders with no cached value yet) is far larger than that -
-- the remaining backlog just gets picked up a further ~30/minute at a time on subsequent runs
-- until it's fully caught up, then steady-state cost is ~0 since only newly-synced orders ever
-- need checking again. admin_list_online_orders (supabase_orders_sync_tables.sql) reads the
-- cached "GlassThickness" column directly, so the flag is already sitting there with zero added
-- cost by the time anyone opens the Online Orders list page.
-- ORDER LINES BACKFILL (per discovering, while building the Top Selling Items report, that
-- public."OnlineOrderLines" was completely empty - 2205 orders, 0 with lines - because no
-- automatic path had ever populated it: this header-only cron never touched lines, the manual
-- admin_sync_online_orders_from_pancake button has no UI trigger wired up, and admin_get_online_
-- order_detail_live is fetch-for-display-only, never persisted). Same "compute once, cache
-- forever" bounded-per-run pattern as the glass thickness backfill just below - up to
-- p_max_lines_detail_calls (default 30) one-off detail fetches for orders with zero rows in
-- OnlineOrderLines, ordered by Last_Updated_At so the most relevant/recent orders backfill first.
-- Deliberately NOT restricted to ReceivedAtShop = false (unlike the glass check) - Top Selling
-- Items intentionally includes walk-in/in-store orders too. See also the one-off
-- admin_backfill_online_order_lines RPC (supabase_backfill_online_order_lines.sql) for catching
-- up the existing backlog faster than ~30/minute from the SQL editor.
drop function if exists public.cron_sync_online_orders_from_pancake(int, int);
drop function if exists public.cron_sync_online_orders_from_pancake(int, int, int);
drop function if exists public.cron_sync_online_orders_from_pancake(int, int, int, int);

create or replace function public.cron_sync_online_orders_from_pancake(
  p_max_pages int default 100,
  p_page_size int default 100,
  p_max_glass_detail_calls int default 30,
  p_max_lines_detail_calls int default 30
)
returns table(orders_synced int, orders_inserted int, orders_updated int, glass_checked int, lines_checked int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := 'e611861d2fc84607bfbbe1428a432447';
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_page_size int := least(greatest(coalesce(p_page_size, 100), 1), 200);
  -- Raised from 20/50 to 100/300 (per "fix 2"): the shop's order backlog exceeds 2,000 rows
  -- (20 pages x 100/page), so every run was hitting the old page cap before ever reaching a
  -- short/empty page - meaning v_reached_end never became true and PancakeSyncState never
  -- advanced, even though orders were genuinely being synced every 5 minutes. At ~0.5s/page
  -- (observed from cron.job_run_details), 100 pages is ~50s and 300 pages is ~2.5min - both
  -- comfortably inside the 5-minute schedule interval.
  v_max_pages int := least(greatest(coalesce(p_max_pages, 100), 1), 300);
  -- See the "GLASS THICKNESS BACKFILL" header comment above for why this is capped instead of
  -- checking every unchecked order in one run.
  v_max_glass_detail_calls int := least(greatest(coalesce(p_max_glass_detail_calls, 30), 0), 200);
  v_glass_order_id text;
  v_glass_detail_url text;
  v_glass_detail_response extensions.http_response;
  v_glass_detail_body jsonb;
  v_glass_order_el jsonb;
  v_glass_line_items jsonb;
  v_glass_line_item jsonb;
  v_glass_variation_info jsonb;
  v_glass_product_display_id text;
  v_glass_line_name text;
  v_glass_line_note text;
  v_glass_has_12mm boolean;
  v_glass_has_10mm boolean;
  v_glass_thickness text;
  v_glass_checked int := 0;
  v_max_lines_detail_calls int := least(greatest(coalesce(p_max_lines_detail_calls, 30), 0), 200);
  v_lines_order_id text;
  v_lines_detail_url text;
  v_lines_detail_response extensions.http_response;
  v_lines_detail_body jsonb;
  v_lines_order_el jsonb;
  v_lines_items jsonb;
  v_lines_item jsonb;
  v_lines_variation_info jsonb;
  v_lines_product_display_id text;
  v_lines_variation_id text;
  v_lines_qty numeric;
  v_lines_price numeric;
  v_lines_name text;
  v_lines_note text;
  v_lines_line_id text;
  v_lines_checked int := 0;
  v_last_sync_utc timestamptz;
  v_since_qs text := '';
  v_iso text;
  v_page int;
  v_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_items jsonb;
  v_item jsonb;
  v_items_this_page int;
  v_reached_end boolean := false;
  v_order_id text;
  v_rec_flag text;
  v_received_at_shop boolean;
  v_status_raw text;
  v_status text;
  v_customer text;
  v_created_raw text;
  v_created_utc timestamptz;
  v_date date;
  v_time text;
  v_page_id text;
  v_conversation_id text;
  v_location_id text;
  v_money_raw text;
  v_money_to_collect numeric;
  v_prepaid_raw text;
  v_amount_paid numeric;
  v_cod_raw text;
  v_balance numeric;
  v_discount_raw text;
  v_discount numeric;
  v_last_paid_raw text;
  v_last_paid_utc timestamptz;
  v_last_paid_date date;
  v_last_paid_time text;
  v_last_updated_raw text;
  v_last_updated_utc timestamptz;
  v_max_last_updated_seen timestamptz;
  v_converted_last_updated_date date;
  v_for_delivery_kind text;
  v_for_delivery boolean;
  v_shipping_address text;
  v_est_delivery_raw text;
  v_est_delivery_date date;
  v_created_by text;
  v_confirmed_by text;
  v_confirmed_at timestamptz;
  v_was_existing boolean;
  v_orders_synced int := 0;
  v_orders_inserted int := 0;
  v_orders_updated int := 0;
  v_max_run_utc timestamptz := now();
begin
  -- No auth check here - see the header comment above for why (internal, pg_cron-only caller).

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  select "LastSyncUtc" into v_last_sync_utc from public."PancakeSyncState" where "Entity" = '/orders';

  if v_last_sync_utc is not null then
    v_iso := to_char(v_last_sync_utc at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    v_since_qs := '&updated_after=' || v_iso || '&updatedAfter=' || v_iso
      || '&created_after=' || v_iso || '&createdAfter=' || v_iso || '&since=' || v_iso;
  end if;

  for v_page in 1..v_max_pages loop
    v_url := v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key
      || '&page_size=' || v_page_size || '&page=' || v_page || v_since_qs;

    v_response := extensions.http_get(v_url);
    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake orders request failed (HTTP %) on page %.', v_response.status, v_page;
    end if;

    v_body := v_response.content::jsonb;

    v_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'orders') = 'array' then v_body -> 'orders'
      else '[]'::jsonb
    end;

    v_items_this_page := jsonb_array_length(v_items);
    if v_items_this_page = 0 then
      v_reached_end := true;
      exit;
    end if;

    for v_item in select * from jsonb_array_elements(v_items)
    loop
      begin
        v_rec_flag := coalesce(v_item ->> 'received_at_shop', v_item ->> 'receivedAtShop');
        v_received_at_shop := lower(coalesce(trim(v_rec_flag), '')) = 'true';
        if lower(coalesce(trim(v_rec_flag), '')) not in ('true', 'false') then
          continue;
        end if;

        v_order_id := coalesce(
          v_item ->> 'receipt_no', v_item ->> 'receiptNo', v_item ->> 'receipt',
          v_item ->> 'id', v_item ->> 'order_number', v_item ->> 'number'
        );
        if v_order_id is null or trim(v_order_id) = '' then
          continue;
        end if;

        v_status_raw := coalesce(v_item ->> 'status_name', v_item ->> 'status', v_item ->> 'state', v_item ->> 'order_status');
        if lower(trim(coalesce(v_status_raw, ''))) = 'new' then
          continue;
        end if;

        v_last_updated_raw := coalesce(v_item ->> 'updated_at', v_item ->> 'updatedAt', v_item ->> 'last_updated_at', v_item ->> 'lastUpdatedAt');
        v_last_updated_utc := public.pancake_try_parse_timestamptz(v_last_updated_raw);

        -- Track the newest last_updated_at Pancake actually returned this run, regardless of
        -- whether the p_max_pages safety cap is hit before the walk reaches its true end - this
        -- becomes the new cursor below (instead of "now()" gated behind v_reached_end), so
        -- PancakeSyncState always makes forward progress every single run, even a partial one.
        if v_last_updated_utc is not null and (v_max_last_updated_seen is null or v_last_updated_utc > v_max_last_updated_seen) then
          v_max_last_updated_seen := v_last_updated_utc;
        end if;

        if v_last_sync_utc is not null and v_last_updated_utc is not null and v_last_updated_utc <= v_last_sync_utc then
          continue;
        end if;

        v_status := case lower(trim(v_status_raw))
          when 'submitted' then 'Confirmed'
          when 'packing' then 'To Ship'
          when 'packed' then 'To Ship'
          when 'pending' then 'Pending Transfer'
          when '9' then 'Pending Transfer'
          when 'pending_transfer' then 'Pending Transfer'
          when 'pending transfer' then 'Pending Transfer'
          when 'waiting_for_pickup' then 'Pending Transfer'
          when 'waiting for pickup' then 'Pending Transfer'
          when '12' then 'In-Transit'
          when 'wait_print' then 'In-Transit'
          when 'wait print' then 'In-Transit'
          when 'in_transit' then 'In-Transit'
          when 'in-transit' then 'In-Transit'
          when 'shipped' then 'Shipped'
          when 'delivered' then 'Shipped'
          when '2' then 'Shipped'
          when 'received' then 'Received'
          when '3' then 'Received'
          when 'printed' then 'Printed'
          else v_status_raw
        end;

        v_customer := coalesce(
          v_item -> 'customer' ->> 'name', v_item -> 'customer' ->> 'customer_name', v_item -> 'customer' ->> 'full_name',
          v_item ->> 'customer_name', v_item ->> 'customer', v_item ->> 'client_name', v_item ->> 'buyer_name'
        );

        v_created_raw := coalesce(v_item ->> 'inserted_at', v_item ->> 'insertedAt', v_item ->> 'created_at', v_item ->> 'createdAt', v_item ->> 'date', v_item ->> 'created');
        v_created_utc := public.pancake_try_parse_timestamptz(v_created_raw);
        if v_created_utc is not null then
          v_date := (v_created_utc at time zone 'Asia/Manila')::date;
          v_time := to_char(v_created_utc at time zone 'Asia/Manila', 'HH24:MI:SS');
        else
          v_date := null;
          v_time := null;
        end if;

        v_page_id := coalesce(v_item ->> 'page_id', v_item ->> 'pageId', v_item ->> 'page');
        v_conversation_id := coalesce(v_item ->> 'conversation_id', v_item ->> 'conversationId', v_item ->> 'conversation', v_item ->> 'thread_id', v_item ->> 'threadId');
        v_location_id := coalesce(v_item ->> 'warehouse_id', v_item ->> 'warehouseId');

        v_money_raw := coalesce(
          v_item -> 'money_to_collect' ->> 'amount', v_item -> 'money_to_collect' ->> 'value', v_item -> 'money_to_collect' ->> 'total',
          v_item ->> 'money_to_collect', v_item ->> 'moneyToCollect', v_item ->> 'total_price', v_item ->> 'total', v_item ->> 'amount', v_item ->> 'money'
        );
        v_money_to_collect := public.pancake_parse_decimal(v_money_raw);

        v_prepaid_raw := coalesce(
          v_item -> 'prepaid' ->> 'amount', v_item -> 'prepaid' ->> 'value',
          v_item ->> 'prepaid', v_item ->> 'prepaid_amount', v_item ->> 'pre_paid', v_item ->> 'deposit', v_item ->> 'prepayment'
        );
        v_amount_paid := public.pancake_parse_decimal(v_prepaid_raw);

        v_cod_raw := coalesce(
          v_item -> 'cod' ->> 'amount', v_item -> 'cod' ->> 'value',
          v_item ->> 'cod', v_item ->> 'cash_on_delivery', v_item ->> 'balance', v_item ->> 'due', v_item ->> 'amount_due'
        );
        v_balance := public.pancake_parse_decimal(v_cod_raw);

        v_discount_raw := coalesce(v_item ->> 'discount', v_item ->> 'discount_amount', v_item ->> 'discounted_amount');
        v_discount := public.pancake_parse_decimal(v_discount_raw);

        v_last_paid_raw := coalesce(v_item ->> 'last_paid_at', v_item ->> 'lastPaidAt', v_item ->> 'last_payment', v_item ->> 'last_paid', v_item ->> 'last_payment_at');
        v_last_paid_utc := public.pancake_try_parse_timestamptz(v_last_paid_raw);
        if v_last_paid_utc is not null then
          v_last_paid_date := (v_last_paid_utc at time zone 'Asia/Manila')::date;
          v_last_paid_time := to_char(v_last_paid_utc at time zone 'Asia/Manila', 'HH24:MI:SS');
        elsif v_amount_paid > 0 and v_date is not null then
          v_last_paid_date := v_date;
          v_last_paid_time := v_time;
        else
          v_last_paid_date := null;
          v_last_paid_time := null;
        end if;

        v_converted_last_updated_date := case when v_last_updated_utc is not null then (v_last_updated_utc at time zone 'Asia/Manila')::date else null end;

        v_for_delivery_kind := jsonb_typeof(v_item -> 'is_free_shipping');
        v_for_delivery := case v_for_delivery_kind
          when 'boolean' then (v_item ->> 'is_free_shipping')::boolean
          when 'number' then (v_item ->> 'is_free_shipping')::numeric <> 0
          when 'string' then lower(trim(v_item ->> 'is_free_shipping')) in ('true', 'yes', 'y', 'on', '1')
          else false
        end;

        v_shipping_address := coalesce(
          v_item -> 'shipping_address' ->> 'full_address', v_item -> 'shipping_address' ->> 'fullAddress',
          v_item -> 'shipping_address' ->> 'address', v_item -> 'shipping_address' ->> 'formatted_address', v_item -> 'shipping_address' ->> 'formattedAddress',
          v_item ->> 'shipping_address_full', v_item ->> 'shippingAddressFull', v_item ->> 'full_address', v_item ->> 'fullAddress'
        );

        v_est_delivery_raw := coalesce(
          v_item -> 'estimate_delivery_date' ->> 'new', v_item ->> 'estimate_delivery_date',
          v_item -> 'estimated_delivery_date' ->> 'new', v_item ->> 'estimated_delivery_date',
          v_item ->> 'estimatedDeliveryDate', v_item ->> 'delivery_date', v_item ->> 'deliveryDate'
        );
        v_est_delivery_date := case
          when v_est_delivery_raw is null then null
          when v_est_delivery_raw ~ '^\d{4}-\d{2}-\d{2}$' then v_est_delivery_raw::date
          else (public.pancake_try_parse_timestamptz(v_est_delivery_raw) at time zone 'Asia/Manila')::date
        end;

        select t.created_by, t.confirmed_by, t.confirmed_at into v_created_by, v_confirmed_by, v_confirmed_at
        from public.pancake_extract_created_confirmed_by(v_item) t;

        select exists(select 1 from public."OnlineOrders" where "OrderID" = v_order_id) into v_was_existing;

        insert into public."OnlineOrders" (
          "OrderID", "Date", "Time", "Status", "CustomerName", "Page_ID", "Conversation_ID", "LocationID",
          "MoneyToCollect", "AmountPaid", "Discount", "Balance", "ForDelivery", "ShippingAddress",
          "EstimatedDeliveryDate", "Last_Updated_At", "Converted_LastUpdated_At", "LastPaid_Date", "LastPaid_Time", "ReceivedAtShop",
          "CreatedBy", "ConfirmedBy", "ConfirmedAtUtc", "SyncedAtUtc"
        ) values (
          v_order_id, v_date, v_time, v_status, v_customer, v_page_id, v_conversation_id, v_location_id,
          v_money_to_collect, v_amount_paid, v_discount, v_balance, v_for_delivery, v_shipping_address,
          v_est_delivery_date, v_last_updated_utc, v_converted_last_updated_date, v_last_paid_date, v_last_paid_time, v_received_at_shop,
          v_created_by, v_confirmed_by, v_confirmed_at, now()
        )
        on conflict ("OrderID") do update set
          "Date" = excluded."Date",
          "Time" = excluded."Time",
          "Status" = excluded."Status",
          "CustomerName" = excluded."CustomerName",
          "Page_ID" = excluded."Page_ID",
          "Conversation_ID" = excluded."Conversation_ID",
          "LocationID" = excluded."LocationID",
          "MoneyToCollect" = excluded."MoneyToCollect",
          "AmountPaid" = excluded."AmountPaid",
          "Discount" = excluded."Discount",
          "Balance" = excluded."Balance",
          "ForDelivery" = excluded."ForDelivery",
          "ShippingAddress" = excluded."ShippingAddress",
          "EstimatedDeliveryDate" = excluded."EstimatedDeliveryDate",
          "Last_Updated_At" = excluded."Last_Updated_At",
          "Converted_LastUpdated_At" = excluded."Converted_LastUpdated_At",
          "LastPaid_Date" = excluded."LastPaid_Date",
          "LastPaid_Time" = excluded."LastPaid_Time",
          "ReceivedAtShop" = excluded."ReceivedAtShop",
          "CreatedBy" = coalesce(excluded."CreatedBy", "OnlineOrders"."CreatedBy"),
          "ConfirmedBy" = coalesce(excluded."ConfirmedBy", "OnlineOrders"."ConfirmedBy"),
          "ConfirmedAtUtc" = coalesce(excluded."ConfirmedAtUtc", "OnlineOrders"."ConfirmedAtUtc"),
          "SyncedAtUtc" = now();

        v_orders_synced := v_orders_synced + 1;
        if v_was_existing then
          v_orders_updated := v_orders_updated + 1;
        else
          v_orders_inserted := v_orders_inserted + 1;
        end if;
      exception when others then
        null; -- skip malformed order, keep processing the rest
      end;
    end loop;

    if v_items_this_page < v_page_size then
      v_reached_end := true;
      exit;
    end if;
  end loop;

  -- Advance the cursor to the newest last_updated_at Pancake actually returned this run - NOT
  -- "now()", and NOT gated behind ever reaching the true end/p_max_pages cap. This guarantees
  -- forward progress on every single run: even a run that hits the page cap partway through a
  -- large backlog still moves PancakeSyncState ahead to what it genuinely saw, so the very next
  -- 5-minute run resumes from there instead of restarting from page 1 every time. Only falls
  -- back to v_max_run_utc ('now') when a run saw literally no last_updated_at values at all AND
  -- fully reached the end (a genuinely caught-up, empty result) - never on a page-cap cutoff.
  if v_max_last_updated_seen is not null then
    insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
    values ('/orders', v_max_last_updated_seen)
    on conflict ("Entity") do update
      set "LastSyncUtc" = excluded."LastSyncUtc"
      where public."PancakeSyncState"."LastSyncUtc" is null
         or excluded."LastSyncUtc" > public."PancakeSyncState"."LastSyncUtc";
  elsif v_reached_end then
    insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
    values ('/orders', v_max_run_utc)
    on conflict ("Entity") do update
      set "LastSyncUtc" = excluded."LastSyncUtc"
      where public."PancakeSyncState"."LastSyncUtc" is null
         or excluded."LastSyncUtc" > public."PancakeSyncState"."LastSyncUtc";
  end if;

  -- GLASS THICKNESS BACKFILL - see the header comment above. Runs after the header sync/cursor
  -- advance so a slow Pancake response here can never block the header sync's own progress.
  if v_max_glass_detail_calls > 0 then
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

    for v_glass_order_id in
      select "OrderID" from public."OnlineOrders"
      where "GlassThicknessCheckedAt" is null
        and coalesce("ReceivedAtShop", false) is not true
      order by "Last_Updated_At" desc nulls last
      limit v_max_glass_detail_calls
    loop
      begin
        v_glass_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_glass_order_id || '?api_key=' || v_api_key || '&page_size=1000';
        v_glass_detail_response := extensions.http_get(v_glass_detail_url);

        if v_glass_detail_response.status < 200 or v_glass_detail_response.status >= 300 then
          continue; -- leave GlassThicknessCheckedAt null - retried on a future run
        end if;

        v_glass_detail_body := v_glass_detail_response.content::jsonb;
        v_glass_order_el := case
          when jsonb_typeof(v_glass_detail_body -> 'data') = 'object' then v_glass_detail_body -> 'data'
          when jsonb_typeof(v_glass_detail_body) = 'object' then v_glass_detail_body
          else null
        end;
        v_glass_line_items := case
          when v_glass_order_el is not null and jsonb_typeof(v_glass_order_el -> 'items') = 'array' then v_glass_order_el -> 'items'
          else '[]'::jsonb
        end;

        v_glass_has_12mm := false;
        v_glass_has_10mm := false;

        for v_glass_line_item in select * from jsonb_array_elements(v_glass_line_items)
        loop
          v_glass_variation_info := v_glass_line_item -> 'variation_info';
          v_glass_product_display_id := coalesce(v_glass_variation_info ->> 'product_display_id', v_glass_line_item ->> 'product_display_id');
          v_glass_line_name := coalesce(v_glass_variation_info ->> 'name', v_glass_line_item ->> 'name');
          v_glass_line_note := v_glass_line_item ->> 'note';

          if regexp_replace(coalesce(v_glass_line_name, '') || ' ' || coalesce(v_glass_line_note, '') || ' ' || coalesce(v_glass_product_display_id, ''), '\s+', '', 'g') ilike '%12mm%' then
            v_glass_has_12mm := true;
          elsif regexp_replace(coalesce(v_glass_line_name, '') || ' ' || coalesce(v_glass_line_note, '') || ' ' || coalesce(v_glass_product_display_id, ''), '\s+', '', 'g') ilike '%10mm%' then
            v_glass_has_10mm := true;
          end if;
        end loop;

        v_glass_thickness := case when v_glass_has_12mm then '12mm' when v_glass_has_10mm then '10mm' else null end;
        update public."OnlineOrders"
          set "GlassThickness" = v_glass_thickness, "GlassThicknessCheckedAt" = now()
          where "OrderID" = v_glass_order_id;

        v_glass_checked := v_glass_checked + 1;
      exception when others then
        null; -- skip this order's glass check, retried on a future run
      end;
    end loop;
  end if;

  -- ORDER LINES BACKFILL - see the header comment above. Runs after the glass thickness pass so
  -- neither can block the other's progress; each order costs one extra Pancake detail call,
  -- same as the glass check, but is not filtered to ReceivedAtShop = false.
  if v_max_lines_detail_calls > 0 then
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

    for v_lines_order_id in
      select o."OrderID" from public."OnlineOrders" o
      where not exists (select 1 from public."OnlineOrderLines" l where l."OrderID" = o."OrderID")
      order by o."Last_Updated_At" desc nulls last
      limit v_max_lines_detail_calls
    loop
      begin
        v_lines_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_lines_order_id || '?api_key=' || v_api_key || '&page_size=1000';
        v_lines_detail_response := extensions.http_get(v_lines_detail_url);

        if v_lines_detail_response.status < 200 or v_lines_detail_response.status >= 300 then
          continue; -- no OnlineOrderLines rows written - retried on a future run
        end if;

        v_lines_detail_body := v_lines_detail_response.content::jsonb;
        v_lines_order_el := case
          when jsonb_typeof(v_lines_detail_body -> 'data') = 'object' then v_lines_detail_body -> 'data'
          when jsonb_typeof(v_lines_detail_body) = 'object' then v_lines_detail_body
          else null
        end;
        v_lines_items := case
          when v_lines_order_el is not null and jsonb_typeof(v_lines_order_el -> 'items') = 'array' then v_lines_order_el -> 'items'
          else '[]'::jsonb
        end;

        for v_lines_item in select * from jsonb_array_elements(v_lines_items)
        loop
          begin
            v_lines_variation_info := v_lines_item -> 'variation_info';
            v_lines_product_display_id := coalesce(v_lines_variation_info ->> 'product_display_id', v_lines_item ->> 'product_display_id');
            if v_lines_product_display_id is null or trim(v_lines_product_display_id) = '' then
              continue;
            end if;

            v_lines_variation_id := coalesce(v_lines_variation_info ->> 'variation_id', v_lines_item ->> 'variation_id', v_lines_item ->> 'variationId');
            v_lines_qty := public.pancake_parse_decimal(v_lines_item ->> 'quantity');
            v_lines_price := public.pancake_parse_decimal(coalesce(v_lines_variation_info ->> 'retail_price', v_lines_item ->> 'retail_price'));
            v_lines_name := coalesce(v_lines_variation_info ->> 'name', v_lines_item ->> 'name');
            v_lines_note := v_lines_item ->> 'note';
            v_lines_line_id := coalesce(
              v_lines_item ->> 'line_id', v_lines_item ->> 'id', v_lines_item ->> 'order_line_id',
              v_lines_item ->> 'order_item_id', v_lines_item ->> 'item_id', ''
            );

            insert into public."OnlineOrderLines" (
              "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "GrossAmount", "Note", "Description", "SyncedAtUtc"
            ) values (
              v_lines_order_id, v_lines_line_id, v_lines_product_display_id, v_lines_product_display_id, nullif(v_lines_variation_id, ''), v_lines_qty, null, v_lines_price, v_lines_price * v_lines_qty, nullif(v_lines_note, ''), nullif(v_lines_name, ''), now()
            )
            on conflict ("OrderID", "LineID") do update set
              "ItemCode" = excluded."ItemCode",
              "product_display_id" = excluded."product_display_id",
              "VariationId" = excluded."VariationId",
              "Quantity" = excluded."Quantity",
              "Price" = excluded."Price",
              "GrossAmount" = excluded."GrossAmount",
              "Note" = excluded."Note",
              "Description" = excluded."Description",
              "SyncedAtUtc" = now();
          exception when others then
            null; -- skip malformed line, keep processing the rest
          end;
        end loop;

        v_lines_checked := v_lines_checked + 1;
      exception when others then
        null; -- skip this order's lines fetch, retried on a future run
      end;
    end loop;
  end if;

  return query select v_orders_synced, v_orders_inserted, v_orders_updated, v_glass_checked, v_lines_checked;
end;
$$;

-- Deliberately NO grant to anon here - see the header comment above.

-- Schedule it every minute via pg_cron. Unschedule-then-reschedule (swallowing the "job
-- doesn't exist yet" error from unschedule) keeps this idempotent across re-deploys of this
-- whole file, instead of erroring on a duplicate job name or silently creating a second one.
-- Requires the pg_cron extension to be enabled first (Supabase dashboard: Database ->
-- Extensions -> pg_cron, or `create extension if not exists pg_cron;` if your plan allows
-- enabling it directly from SQL).
--
-- NOTE on overlap: pg_cron does NOT wait for a run to finish before starting the next one, so
-- at a 1-minute interval a slow run (e.g. one that has to walk many pages of backlog) can still
-- be in flight when the next tick fires. This is safe here because every write in this function
-- is either an idempotent upsert (OnlineOrders keyed by "OrderID") or a guarded monotonic cursor
-- advance (PancakeSyncState only ever moves forward, never backward) - concurrent/overlapping
-- runs cannot corrupt state, just do some redundant work. If Pancake ever rate-limits or this
-- causes noticeable load, widen the interval back up (e.g. '*/2 * * * *').
do $$
begin
  perform cron.unschedule('sync-online-orders-from-pancake');
exception when others then
  null; -- job didn't exist yet - nothing to unschedule
end;
$$;

select cron.schedule(
  'sync-online-orders-from-pancake',
  '* * * * *',
  $$select public.cron_sync_online_orders_from_pancake();$$
);

-- ---------------------------------------------------------------------------
-- LIVE Online Orders view - per "is it possible to just show the orders via
-- api and not sync manually?": fetches straight from Pancake on every call and
-- returns rows directly to the portal. Uses is_staff_authorized() (any active
-- staff), matching the relaxed Online Orders viewing access.
--
-- AUTOMATIC HEADER PERSISTENCE (per "can we insert the chunk data into
-- Supabase as well while it's loading?"): as each page is fetched from
-- Pancake for display, every valid order's header is also upserted into
-- public."OnlineOrders" (see the insert further below), regardless of the
-- caller's search/status filter. This means simply browsing the Online
-- Orders page keeps the persisted mirror table (and therefore the status
-- summary counts / admin_list_online_orders) fresh automatically, without
-- depending on the desktop app's own push sync or the manual "Sync from
-- Pancake" button. Order LINES are intentionally NOT persisted here (that
-- would need one extra Pancake HTTP call per order, reintroducing the N+1
-- slowness this function was rewritten to avoid) - lines stay covered by
-- admin_get_online_order_detail_live (fetched on demand per order) and by
-- the desktop app / manual sync button for the persisted copy.
--
-- SINGLE-PAGE-PER-CALL, CHUNKED DISPLAY: earlier versions of this function
-- looped over several Pancake pages (up to 5, then 3) inside ONE call, which
-- could still add up to more wall-clock time than Supabase's hosted API
-- gateway allows for a single request - that shows up as "HTTP request
-- cancelled" (the http extension's curl progress callback noticing Postgres's
-- own query-cancel flag mid-request and aborting the transfer - a genuinely
-- different, uncatchable code path from a plain timeout, since plpgsql's
-- `exception when others` cannot catch a real query cancellation). Since even
-- 3 sequential Pancake calls in one request was apparently still too slow,
-- this function now fetches exactly ONE Pancake page per call (bounded,
-- fast), and the portal (onlineOrders.js) instead loops CLIENT-SIDE - one RPC
-- call per page - appending results to the table as each page arrives
-- ("chunked display") and stopping once `has_more` comes back false or a
-- page returns no rows. This keeps every single RPC call small and fast
-- regardless of how many total orders exist.
--
-- INCREMENTAL "SINCE LAST SYNC" FILTERING (per "filter out the last updated
-- date on Pancake using the last sync on Supabase"): a plain, unfiltered
-- browse (no search/status typed in) reuses the SAME PancakeSyncState
-- ('/orders' entity row) cursor as the manual "Sync from Pancake" deep sync (admin_sync_online_
-- orders_from_pancake) - whichever of the two last successfully caught
-- Supabase up with Pancake. Once that cursor is set, subsequent plain
-- browses only ask Pancake for orders updated_after/since that point, so a
-- normal reload no longer has to walk every single historical page (see the
-- screenshot that prompted this - 12+ full pages on every reload) - it
-- typically finishes in 1-2 pages. The client passes p_walk_started_at (the
-- wall-clock time it began THIS load, captured once - not per page) on every
-- page call of the same walk; once a call reports has_more = false, that
-- timestamp becomes the new cursor. An ACTIVE search or status filter always
-- disables this shortcut and walks the full unfiltered catalog instead -
-- otherwise an old, not-recently-updated order that matches the search text
-- would silently fail to appear just because it's outside the incremental
-- window (it's still safe/fast for search, since the persisted table already
-- covers most orders and this is only reached outside the throttle window).

drop function if exists public.admin_list_online_orders_live(text, text, text, text, int, int);

create or replace function public.admin_list_online_orders_live(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_page int default 1,
  p_page_size int default 100,
  p_walk_started_at timestamptz default null
)
returns table(
  order_id text,
  order_date date,
  order_time text,
  status text,
  customer_name text,
  location_id text,
  warehouse_name text,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
  balance numeric,
  for_delivery boolean,
  shipping_address text,
  estimated_delivery_date date,
  last_updated_at timestamptz,
  has_more boolean,
  debug_url text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := 'e611861d2fc84607bfbbe1428a432447';
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_page_size int := least(greatest(coalesce(p_page_size, 100), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_url text;
  v_last_sync_utc timestamptz;
  v_apply_since_filter boolean;
  v_since_qs text := '';
  v_iso text;
  v_response extensions.http_response;
  v_body jsonb;
  v_items jsonb;
  v_item jsonb;
  v_items_this_page int;
  v_has_more boolean;
  v_row_count int := 0;
  v_order_id text;
  v_rec_flag text;
  v_received_at_shop boolean;
  v_status_raw text;
  v_status text;
  v_customer text;
  v_created_raw text;
  v_created_utc timestamptz;
  v_date date;
  v_time text;
  v_location_id text;
  v_money_raw text;
  v_money_to_collect numeric;
  v_prepaid_raw text;
  v_amount_paid numeric;
  v_cod_raw text;
  v_balance numeric;
  v_discount_raw text;
  v_discount numeric;
  v_last_updated_raw text;
  v_last_updated_utc timestamptz;
  v_for_delivery_kind text;
  v_for_delivery boolean;
  v_shipping_address text;
  v_est_delivery_raw text;
  v_est_delivery_date date;
  v_matches_filters boolean;
  v_warehouse_name text;
  v_created_by text;
  v_confirmed_by text;
  v_confirmed_at timestamptz;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Only ever ONE Pancake call per invocation now, so a generous-but-bounded
  -- per-call timeout is fine - it can't accumulate into an external cancel.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  -- Only skip straight to "what changed since last time" when browsing with no active
  -- search/status filter - see the header comment above for why search always walks
  -- the full catalog instead.
  v_apply_since_filter := (p_search is null or trim(p_search) = '') and (p_status is null or trim(p_status) = '');

  if v_apply_since_filter then
    select "LastSyncUtc" into v_last_sync_utc from public."PancakeSyncState" where "Entity" = '/orders';
    if v_last_sync_utc is not null then
      v_iso := to_char(v_last_sync_utc at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
      v_since_qs := '&updated_after=' || v_iso || '&updatedAfter=' || v_iso
        || '&created_after=' || v_iso || '&createdAfter=' || v_iso || '&since=' || v_iso;
    end if;
  end if;

  v_url := v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key
    || '&page_size=' || v_page_size || '&page=' || v_page || v_since_qs;

  v_response := extensions.http_get(v_url);
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake orders request failed (HTTP %) on page %.', v_response.status, v_page;
  end if;

  v_body := v_response.content::jsonb;

  v_items := case
    when jsonb_typeof(v_body) = 'array' then v_body
    when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'orders') = 'array' then v_body -> 'orders'
    else '[]'::jsonb
  end;

  v_items_this_page := jsonb_array_length(v_items);
  -- A full raw page (before our own filters below) means there's likely a next page to fetch.
  v_has_more := (v_items_this_page = v_page_size);

  -- Once a since-filtered walk reaches its last page, advance the shared cursor so the NEXT
  -- plain browse only asks for what changed after this walk started. Guarded so a slower,
  -- overlapping call can never move the cursor backwards. Skipped entirely for search/status-
  -- filtered walks (v_apply_since_filter false) and for callers that didn't pass a start time.
  if not v_has_more and v_apply_since_filter and p_walk_started_at is not null then
    insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
    values ('/orders', p_walk_started_at)
    on conflict ("Entity") do update
      set "LastSyncUtc" = excluded."LastSyncUtc"
      where public."PancakeSyncState"."LastSyncUtc" is null
         or excluded."LastSyncUtc" > public."PancakeSyncState"."LastSyncUtc";
  end if;

  for v_item in select * from jsonb_array_elements(v_items)
  loop
    begin
      v_rec_flag := coalesce(v_item ->> 'received_at_shop', v_item ->> 'receivedAtShop');
      v_received_at_shop := lower(coalesce(trim(v_rec_flag), '')) = 'true';
      if lower(coalesce(trim(v_rec_flag), '')) not in ('true', 'false') then
        continue;
      end if;

      v_order_id := coalesce(
        v_item ->> 'receipt_no', v_item ->> 'receiptNo', v_item ->> 'receipt',
        v_item ->> 'id', v_item ->> 'order_number', v_item ->> 'number'
      );
      if v_order_id is null or trim(v_order_id) = '' then
        continue;
      end if;

      v_status_raw := coalesce(v_item ->> 'status_name', v_item ->> 'status', v_item ->> 'state', v_item ->> 'order_status');
      if lower(trim(coalesce(v_status_raw, ''))) = 'new' then
        continue;
      end if;

      v_status := case lower(trim(v_status_raw))
        when 'submitted' then 'Confirmed'
        when 'packing' then 'To Ship'
        when 'packed' then 'To Ship'
        when 'pending' then 'Pending Transfer'
        when '9' then 'Pending Transfer'
        when 'pending_transfer' then 'Pending Transfer'
        when 'pending transfer' then 'Pending Transfer'
        when 'waiting_for_pickup' then 'Pending Transfer'
        when 'waiting for pickup' then 'Pending Transfer'
        when '12' then 'In-Transit'
        when 'wait_print' then 'In-Transit'
        when 'wait print' then 'In-Transit'
        when 'in_transit' then 'In-Transit'
        when 'in-transit' then 'In-Transit'
        when 'shipped' then 'Shipped'
        when 'delivered' then 'Shipped'
        when '2' then 'Shipped'
        when 'received' then 'Received'
        when '3' then 'Received'
        when 'printed' then 'Printed'
        else v_status_raw
      end;

      -- NOTE: filter mismatches no longer `continue` here - every valid order on this page still
      -- gets its fields computed and persisted below (see v_matches_filters), so browsing with a
      -- search/status filter active doesn't silently skip persisting the orders being filtered out.
      v_matches_filters := not (p_status is not null and trim(p_status) <> '' and v_status not ilike '%' || p_status || '%');

      v_customer := coalesce(
        v_item -> 'customer' ->> 'name', v_item -> 'customer' ->> 'customer_name', v_item -> 'customer' ->> 'full_name',
        v_item ->> 'customer_name', v_item ->> 'customer', v_item ->> 'client_name', v_item ->> 'buyer_name'
      );

      if v_matches_filters and p_search is not null and trim(p_search) <> ''
         and v_order_id not ilike '%' || p_search || '%'
         and coalesce(v_customer, '') not ilike '%' || p_search || '%' then
        v_matches_filters := false;
      end if;

      v_created_raw := coalesce(v_item ->> 'inserted_at', v_item ->> 'insertedAt', v_item ->> 'created_at', v_item ->> 'createdAt', v_item ->> 'date', v_item ->> 'created');
      v_created_utc := public.pancake_try_parse_timestamptz(v_created_raw);
      if v_created_utc is not null then
        v_date := (v_created_utc at time zone 'Asia/Manila')::date;
        v_time := to_char(v_created_utc at time zone 'Asia/Manila', 'HH24:MI:SS');
      else
        v_date := null;
        v_time := null;
      end if;

      v_location_id := coalesce(v_item ->> 'warehouse_id', v_item ->> 'warehouseId');

      -- Resolve the human-readable warehouse name (public."Warehouses" is kept in sync by
      -- admin_sync_warehouses_from_pancake / the desktop app's own warehouse sync) - falls back
      -- to null (client displays the raw location_id instead) if no match is found.
      select "Name" into v_warehouse_name from public."Warehouses" where "ID" = v_location_id;

      v_money_raw := coalesce(
        v_item -> 'money_to_collect' ->> 'amount', v_item -> 'money_to_collect' ->> 'value', v_item -> 'money_to_collect' ->> 'total',
        v_item ->> 'money_to_collect', v_item ->> 'moneyToCollect', v_item ->> 'total_price', v_item ->> 'total', v_item ->> 'amount', v_item ->> 'money'
      );
      v_money_to_collect := public.pancake_parse_decimal(v_money_raw);

      v_prepaid_raw := coalesce(
        v_item -> 'prepaid' ->> 'amount', v_item -> 'prepaid' ->> 'value',
        v_item ->> 'prepaid', v_item ->> 'prepaid_amount', v_item ->> 'pre_paid', v_item ->> 'deposit', v_item ->> 'prepayment'
      );
      v_amount_paid := public.pancake_parse_decimal(v_prepaid_raw);

      v_cod_raw := coalesce(
        v_item -> 'cod' ->> 'amount', v_item -> 'cod' ->> 'value',
        v_item ->> 'cod', v_item ->> 'cash_on_delivery', v_item ->> 'balance', v_item ->> 'due', v_item ->> 'amount_due'
      );
      v_balance := public.pancake_parse_decimal(v_cod_raw);

      v_discount_raw := coalesce(v_item ->> 'discount', v_item ->> 'discount_amount', v_item ->> 'discounted_amount');
      v_discount := public.pancake_parse_decimal(v_discount_raw);

      v_last_updated_raw := coalesce(v_item ->> 'updated_at', v_item ->> 'updatedAt', v_item ->> 'last_updated_at', v_item ->> 'lastUpdatedAt');
      v_last_updated_utc := public.pancake_try_parse_timestamptz(v_last_updated_raw);

      v_for_delivery_kind := jsonb_typeof(v_item -> 'is_free_shipping');
      v_for_delivery := case v_for_delivery_kind
        when 'boolean' then (v_item ->> 'is_free_shipping')::boolean
        when 'number' then (v_item ->> 'is_free_shipping')::numeric <> 0
        when 'string' then lower(trim(v_item ->> 'is_free_shipping')) in ('true', 'yes', 'y', 'on', '1')
        else false
      end;

      v_shipping_address := coalesce(
        v_item -> 'shipping_address' ->> 'full_address', v_item -> 'shipping_address' ->> 'fullAddress',
        v_item -> 'shipping_address' ->> 'address', v_item -> 'shipping_address' ->> 'formatted_address', v_item -> 'shipping_address' ->> 'formattedAddress',
        v_item ->> 'shipping_address_full', v_item ->> 'shippingAddressFull', v_item ->> 'full_address', v_item ->> 'fullAddress'
      );

      v_est_delivery_raw := coalesce(
        v_item -> 'estimate_delivery_date' ->> 'new', v_item ->> 'estimate_delivery_date',
        v_item -> 'estimated_delivery_date' ->> 'new', v_item ->> 'estimated_delivery_date',
        v_item ->> 'estimatedDeliveryDate', v_item ->> 'delivery_date', v_item ->> 'deliveryDate'
      );
      v_est_delivery_date := case
        when v_est_delivery_raw is null then null
        when v_est_delivery_raw ~ '^\d{4}-\d{2}-\d{2}$' then v_est_delivery_raw::date
        else (public.pancake_try_parse_timestamptz(v_est_delivery_raw) at time zone 'Asia/Manila')::date
      end;

      -- AUTOMATIC PERSISTENCE: upsert this order's header into the local mirror table as it's
      -- fetched for live display, regardless of whether it matches the caller's search/status
      -- filter - this is what keeps public."OnlineOrders" (and therefore the status summary
      -- counts and the non-live admin_list_online_orders) populated automatically just from
      -- staff browsing the Online Orders page, without needing the desktop app's push sync or
      -- the manual "Sync from Pancake" button to have run first. Order LINES are deliberately
      -- NOT synced here - that needs one extra Pancake HTTP call per order, which would turn
      -- this single-page-per-call function back into the slow N+1 pattern it was rewritten to
      -- avoid (see the comment above this function). Lines are instead fetched live, on demand,
      -- by admin_get_online_order_detail_live when a specific order is opened, or filled in by
      -- the desktop app / the manual sync button. Best-effort: a persistence failure must never
      -- prevent the row from still being shown to the caller.
      --
      -- SKIP-IF-UNCHANGED: the `where` clause on the conflict update means Postgres only
      -- actually rewrites the row when Pancake's own "Last_Updated_At" (or Status, as a
      -- fallback for orders Pancake doesn't return an updated_at for) differs from what's
      -- already stored - since every staff page-load re-fetches and re-upserts the same
      -- orders, this avoids needless writes for orders that haven't changed since they were
      -- last persisted. No extra table/read needed - "Last_Updated_At"/"SyncedAtUtc" already
      -- live on this same row and are what track "when did this order last change" (Pancake's
      -- timestamp) vs. "when did we last touch this row" (ours) respectively.
      select t.created_by, t.confirmed_by, t.confirmed_at into v_created_by, v_confirmed_by, v_confirmed_at
      from public.pancake_extract_created_confirmed_by(v_item) t;

      begin
        insert into public."OnlineOrders" (
          "OrderID", "Date", "Time", "Status", "CustomerName", "LocationID",
          "MoneyToCollect", "AmountPaid", "Discount", "Balance", "ForDelivery", "ShippingAddress",
          "EstimatedDeliveryDate", "Last_Updated_At", "ReceivedAtShop", "CreatedBy", "ConfirmedBy", "ConfirmedAtUtc", "SyncedAtUtc"
        ) values (
          v_order_id, v_date, v_time, v_status, v_customer, v_location_id,
          v_money_to_collect, v_amount_paid, v_discount, v_balance, v_for_delivery, v_shipping_address,
          v_est_delivery_date, v_last_updated_utc, v_received_at_shop, v_created_by, v_confirmed_by, v_confirmed_at, now()
        )
        on conflict ("OrderID") do update set
          "Date" = excluded."Date",
          "Time" = excluded."Time",
          "Status" = excluded."Status",
          "CustomerName" = excluded."CustomerName",
          "LocationID" = excluded."LocationID",
          "MoneyToCollect" = excluded."MoneyToCollect",
          "AmountPaid" = excluded."AmountPaid",
          "Discount" = excluded."Discount",
          "Balance" = excluded."Balance",
          "ForDelivery" = excluded."ForDelivery",
          "ShippingAddress" = excluded."ShippingAddress",
          "EstimatedDeliveryDate" = excluded."EstimatedDeliveryDate",
          "Last_Updated_At" = excluded."Last_Updated_At",
          "ReceivedAtShop" = excluded."ReceivedAtShop",
          "CreatedBy" = coalesce(excluded."CreatedBy", "OnlineOrders"."CreatedBy"),
          "ConfirmedBy" = coalesce(excluded."ConfirmedBy", "OnlineOrders"."ConfirmedBy"),
          "ConfirmedAtUtc" = coalesce(excluded."ConfirmedAtUtc", "OnlineOrders"."ConfirmedAtUtc"),
          "SyncedAtUtc" = now()
        where public."OnlineOrders"."Last_Updated_At" is distinct from excluded."Last_Updated_At"
           or public."OnlineOrders"."Status" is distinct from excluded."Status"
           or public."OnlineOrders"."ReceivedAtShop" is distinct from excluded."ReceivedAtShop"
           or (excluded."ConfirmedBy" is not null and public."OnlineOrders"."ConfirmedBy" is distinct from excluded."ConfirmedBy")
           or (excluded."CreatedBy" is not null and public."OnlineOrders"."CreatedBy" is distinct from excluded."CreatedBy");
      exception when others then
        null; -- persistence is best-effort - never let it block showing the live row
      end;

      -- Walk-in/in-store orders (ReceivedAtShop = true) are persisted above so dashboard
      -- reporting (Walk-In Sales) picks them up, but are never returned to this live-browse
      -- caller - the Online Orders page is specifically for online/delivery orders, matching
      -- its behavior before walk-in orders were captured at all.
      if v_received_at_shop or not v_matches_filters then
        continue;
      end if;

      v_row_count := v_row_count + 1;
      order_id := v_order_id;
      order_date := v_date;
      order_time := v_time;
      status := v_status;
      customer_name := v_customer;
      location_id := v_location_id;
      warehouse_name := v_warehouse_name;
      money_to_collect := v_money_to_collect;
      amount_paid := v_amount_paid;
      discount := v_discount;
      balance := v_balance;
      for_delivery := v_for_delivery;
      shipping_address := v_shipping_address;
      estimated_delivery_date := v_est_delivery_date;
      last_updated_at := v_last_updated_utc;
      has_more := v_has_more;
      debug_url := v_url;
      return next;
    exception when others then
      null; -- skip malformed order row, keep processing the rest
    end;
  end loop;

  -- If every item on this page got filtered out (e.g. all "new"/search mismatch), still emit
  -- one sentinel row so the client learns has_more without seeing a false "no orders" result.
  -- The client treats order_id IS NULL as "not a real order, just a has_more signal" and skips it.
  if v_row_count = 0 then
    order_id := null;
    order_date := null;
    order_time := null;
    status := null;
    customer_name := null;
    location_id := null;
    warehouse_name := null;
    money_to_collect := null;
    amount_paid := null;
    discount := null;
    balance := null;
    for_delivery := null;
    shipping_address := null;
    estimated_delivery_date := null;
    last_updated_at := null;
    has_more := v_has_more;
    debug_url := v_url;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_list_online_orders_live(text, text, text, text, int, int, timestamptz) to anon;

-- Single-order detail, LIVE: used by the lines drill-down page for both the header
-- summary line and the line items themselves in one Pancake call (no persistence).
drop function if exists public.admin_get_online_order_detail_live(text, text, text);

create or replace function public.admin_get_online_order_detail_live(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(
  order_id text,
  status text,
  customer_name text,
  line_id text,
  item_code text,
  product_display_id text,
  variation_id text,
  quantity numeric,
  price numeric,
  gross_amount numeric,
  description text,
  note text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := 'e611861d2fc84607bfbbe1428a432447';
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_detail_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_order_el jsonb;
  v_status_raw text;
  v_status text;
  v_customer text;
  v_line_items jsonb;
  v_line_item jsonb;
  v_variation_info jsonb;
  v_product_display_id text;
  v_variation_id text;
  v_qty numeric;
  v_price numeric;
  v_line_name text;
  v_line_id text;
  v_line_note text;
  v_row_count int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_order_id is null or trim(p_order_id) = '' then
    raise exception 'Order ID is required.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  v_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || p_order_id || '?api_key=' || v_api_key || '&page_size=1000';
  v_response := extensions.http_get(v_detail_url);
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake order detail request failed (HTTP %).', v_response.status;
  end if;

  v_body := v_response.content::jsonb;
  v_order_el := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' then v_body
    else null
  end;

  if v_order_el is null then
    raise exception 'Order % not found.', p_order_id;
  end if;

  v_status_raw := coalesce(v_order_el ->> 'status_name', v_order_el ->> 'status', v_order_el ->> 'state', v_order_el ->> 'order_status');
  v_status := case lower(trim(v_status_raw))
    when 'submitted' then 'Confirmed'
    when 'packing' then 'To Ship'
    when 'packed' then 'To Ship'
    when 'pending' then 'Pending Transfer'
    when '9' then 'Pending Transfer'
    when 'pending_transfer' then 'Pending Transfer'
    when 'pending transfer' then 'Pending Transfer'
    when 'waiting_for_pickup' then 'Pending Transfer'
    when 'waiting for pickup' then 'Pending Transfer'
    when '12' then 'In-Transit'
    when 'wait_print' then 'In-Transit'
    when 'wait print' then 'In-Transit'
    when 'in_transit' then 'In-Transit'
    when 'in-transit' then 'In-Transit'
    when 'shipped' then 'Shipped'
    when 'delivered' then 'Shipped'
    when '2' then 'Shipped'
    when 'received' then 'Received'
    when '3' then 'Received'
    when 'printed' then 'Printed'
    else v_status_raw
  end;

  v_customer := coalesce(
    v_order_el -> 'customer' ->> 'name', v_order_el -> 'customer' ->> 'customer_name', v_order_el -> 'customer' ->> 'full_name',
    v_order_el ->> 'customer_name', v_order_el ->> 'customer', v_order_el ->> 'client_name', v_order_el ->> 'buyer_name'
  );

  v_line_items := case
    when jsonb_typeof(v_order_el -> 'items') = 'array' then v_order_el -> 'items'
    else '[]'::jsonb
  end;

  for v_line_item in select * from jsonb_array_elements(v_line_items)
  loop
    begin
      v_variation_info := v_line_item -> 'variation_info';
      v_product_display_id := coalesce(v_variation_info ->> 'product_display_id', v_line_item ->> 'product_display_id');
      if v_product_display_id is null or trim(v_product_display_id) = '' then
        continue;
      end if;

      v_variation_id := coalesce(v_variation_info ->> 'variation_id', v_line_item ->> 'variation_id', v_line_item ->> 'variationId');
      v_qty := public.pancake_parse_decimal(v_line_item ->> 'quantity');
      v_price := public.pancake_parse_decimal(coalesce(v_variation_info ->> 'retail_price', v_line_item ->> 'retail_price'));
      v_line_name := coalesce(v_variation_info ->> 'name', v_line_item ->> 'name');
      v_line_id := coalesce(
        v_line_item ->> 'line_id', v_line_item ->> 'id', v_line_item ->> 'order_line_id',
        v_line_item ->> 'order_item_id', v_line_item ->> 'item_id', ''
      );
      v_line_note := v_line_item ->> 'note';

      v_row_count := v_row_count + 1;
      order_id := p_order_id;
      status := v_status;
      customer_name := v_customer;
      line_id := v_line_id;
      item_code := v_product_display_id;
      product_display_id := v_product_display_id;
      variation_id := nullif(v_variation_id, '');
      quantity := v_qty;
      price := v_price;
      gross_amount := v_price * v_qty;
      description := nullif(v_line_name, '');
      note := nullif(v_line_note, '');
      return next;
    exception when others then
      null; -- skip malformed line, keep processing the rest
    end;
  end loop;

  if v_row_count = 0 then
    order_id := p_order_id;
    status := v_status;
    customer_name := v_customer;
    line_id := null;
    item_code := null;
    product_display_id := null;
    variation_id := null;
    quantity := null;
    price := null;
    gross_amount := null;
    description := null;
    note := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_online_order_detail_live(text, text, text) to anon;
