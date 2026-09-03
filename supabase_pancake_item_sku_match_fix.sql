-- BUGFIX: the Items sync was silently merging brand-new products into random UNRELATED existing
-- Items rows instead of creating a new row for them - discovered while investigating why a new,
-- variant-less product (PI-037) never appeared in Items after a successful sync.
--
-- Root cause: for a product with no variations, its "SKU" can only be sourced from Pancake's
-- bare product-level "display_id" - a small numeric sequence number this file's own comments
-- already flagged as "NOT the human-facing code" (see the Phase 1 field-mapping note below).
-- That value turns out to be small and non-unique in this shop's data - confirmed live, 9+
-- completely unrelated existing Items rows (AS-014, CI-011, CI-012, CI-013, SERVICES, ALL-FISH,
-- L-5w, ...) all share SKU = '1'. The existing-row match query used `(SKU = t.sku) OR (Code =
-- t.code)` - a plain OR, not a real priority fallback - so ANY new/re-synced product whose
-- computed SKU happened to collide with one of these matched THAT unrelated row instead of its
-- own code, and the subsequent UPDATE overwrote that row's Name/Price/Category/ProductId with
-- the new product's data. This explains both PI-037 never getting its own row, AND why some of
-- those 9 rows appeared to have their identity "flip-flop" between unrelated products across
-- different sync runs (whichever product last won the ambiguous SKU match).
--
-- Fix: stop matching on SKU entirely. Match only on "ProductId" (Pancake's own stable id -
-- already the primary/preferred key in the Variants phase, see that phase's own comment) with an
-- exact "Code" match as the sole fallback - both are genuinely unique, so this class of
-- accidental-merge collision becomes impossible. A genuinely new product with no ProductId match
-- yet and no existing Code match now correctly falls through to an INSERT instead of colliding.
--
-- This redefines admin_sync_items_from_pancake, cron_sync_items_from_pancake (used by the
-- existing */5 * * * * pg_cron schedule - no need to reschedule, it calls the function by name),
-- and admin_list_items_live (see supabase_pancake_manual_sync.sql for all three original
-- definitions) - run this once in the Supabase SQL editor to apply it. Does NOT touch/repair rows
-- already corrupted by the old logic - see the follow-up audit query mentioned alongside this fix
-- for finding and manually correcting those.

drop function if exists public.admin_sync_items_from_pancake(text, text);

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
  v_products_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products?api_key=' || public._pancake_api_key();
  v_variations_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products/variations?api_key=' || public._pancake_api_key();
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
    description text,
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
    insert into tmp_pancake_products (code, sku, name, description, price, category, product_id, images)
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
      -- often end up equal, which is the requested behavior, not a bug. NOTE: this SKU value is
      -- still stored on Items.SKU for display/reference, it just isn't trusted as a MATCH key
      -- below anymore (see the BUGFIX header comment) - a bare-product-level display_id fallback
      -- is too low-confidence/non-unique to safely resolve an existing row.
      coalesce(nullif(product -> 'variations' -> 0 ->> 'display_id', ''), nullif(product ->> 'display_id', '')) as sku,
      product ->> 'name' as name,
      -- The actual customer-facing description Pancake exposes, per direct request (see the
      -- product-detail payload's "note_product" field) - previously not captured at all, so
      -- Items.Description was always just a copy of Name (see the ins/upd statements below).
      nullif(product ->> 'note_product', '') as description,
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

  -- Resolve which existing Items row (if any) each staged product belongs to: ProductId
  -- (Pancake's own stable id) only, falling back to an exact Code match - see the BUGFIX header
  -- comment above for why SKU is no longer used as a match key here.
  create temporary table if not exists tmp_pancake_products_resolved (
    code text,
    sku text,
    name text,
    description text,
    price numeric,
    category text,
    product_id text,
    images text,
    was_existing boolean
  ) on commit drop;
  truncate tmp_pancake_products_resolved;

  insert into tmp_pancake_products_resolved (code, sku, name, description, price, category, product_id, images, was_existing)
  select distinct on (coalesce(existing.matched_code, t.code))
    coalesce(existing.matched_code, t.code) as code,
    t.sku, t.name, t.description, t.price, t.category, t.product_id, t.images,
    (existing.matched_code is not null) as was_existing
  from tmp_pancake_products t
  left join lateral (
    select coalesce(
      (select i."Code" from public."Items" i where t.product_id is not null and i."ProductId" = t.product_id limit 1),
      (select i."Code" from public."Items" i where i."Code" = t.code limit 1)
    ) as matched_code
  ) existing on true
  order by coalesce(existing.matched_code, t.code);

  with upd as (
    update public."Items" i
    set "Name" = coalesce(nullif(r.name, ''), i."Name"),
        -- Description now tracks Pancake's own note_product on every sync (not just once on
        -- insert, per the ins statement below) - per direct request, note_product is the real
        -- customer-facing description and should stay current rather than frozen at whatever it
        -- was the first time this item synced.
        "Description" = coalesce(nullif(r.description, ''), i."Description"),
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
    -- Prefer note_product for Description, falling back to Name only when Pancake has no
    -- note_product set for this product (previously always just copied Name).
    select r.code, r.name, coalesce(nullif(r.description, ''), r.name), r.price, r.category, r.sku, r.product_id, r.images, now()
    from tmp_pancake_products_resolved r
    where not r.was_existing
    returning 1
  )
  select count(*) into v_count from ins;
  v_items_inserted := v_count;

  select count(*) into v_items_synced from tmp_pancake_products_resolved;

  ------------------------------------------------------------------------------------
  -- Phase 2: Variants <- /products/variations (one row per variation, linked back to
  -- the Items row it belongs to - same ProductId-then-Code match precedence as Phase 1).
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
  -- ProductId (Pancake's own stable id) only, falling back to an exact Code match - see the
  -- BUGFIX header comment above for why SKU is no longer used as a match key here either.
  left join lateral (
    select coalesce(
      (select i."Code" from public."Items" i where t.product_id is not null and i."ProductId" = t.product_id limit 1),
      (select i."Code" from public."Items" i where i."Code" = t.main_item_code limit 1)
    ) as matched_code
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

grant execute on function public.admin_sync_items_from_pancake(text, text) to anon;

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
  v_products_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products?api_key=' || public._pancake_api_key();
  v_variations_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products/variations?api_key=' || public._pancake_api_key();
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
    description text,
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
    insert into tmp_pancake_products (code, sku, name, description, price, category, product_id, images)
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
      -- often end up equal, which is the requested behavior, not a bug. NOTE: this SKU value is
      -- still stored on Items.SKU for display/reference, it just isn't trusted as a MATCH key
      -- below anymore (see the BUGFIX header comment) - a bare-product-level display_id fallback
      -- is too low-confidence/non-unique to safely resolve an existing row.
      coalesce(nullif(product -> 'variations' -> 0 ->> 'display_id', ''), nullif(product ->> 'display_id', '')) as sku,
      product ->> 'name' as name,
      -- The actual customer-facing description Pancake exposes, per direct request (see the
      -- product-detail payload's "note_product" field) - previously not captured at all, so
      -- Items.Description was always just a copy of Name (see the ins/upd statements below).
      nullif(product ->> 'note_product', '') as description,
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

  -- Resolve which existing Items row (if any) each staged product belongs to: ProductId
  -- (Pancake's own stable id) only, falling back to an exact Code match - see the BUGFIX header
  -- comment above for why SKU is no longer used as a match key here.
  create temporary table if not exists tmp_pancake_products_resolved (
    code text,
    sku text,
    name text,
    description text,
    price numeric,
    category text,
    product_id text,
    images text,
    was_existing boolean
  ) on commit drop;
  truncate tmp_pancake_products_resolved;

  insert into tmp_pancake_products_resolved (code, sku, name, description, price, category, product_id, images, was_existing)
  select distinct on (coalesce(existing.matched_code, t.code))
    coalesce(existing.matched_code, t.code) as code,
    t.sku, t.name, t.description, t.price, t.category, t.product_id, t.images,
    (existing.matched_code is not null) as was_existing
  from tmp_pancake_products t
  left join lateral (
    select coalesce(
      (select i."Code" from public."Items" i where t.product_id is not null and i."ProductId" = t.product_id limit 1),
      (select i."Code" from public."Items" i where i."Code" = t.code limit 1)
    ) as matched_code
  ) existing on true
  order by coalesce(existing.matched_code, t.code);

  with upd as (
    update public."Items" i
    set "Name" = coalesce(nullif(r.name, ''), i."Name"),
        -- Description now tracks Pancake's own note_product on every sync (not just once on
        -- insert, per the ins statement below) - per direct request, note_product is the real
        -- customer-facing description and should stay current rather than frozen at whatever it
        -- was the first time this item synced.
        "Description" = coalesce(nullif(r.description, ''), i."Description"),
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
    -- Prefer note_product for Description, falling back to Name only when Pancake has no
    -- note_product set for this product (previously always just copied Name).
    select r.code, r.name, coalesce(nullif(r.description, ''), r.name), r.price, r.category, r.sku, r.product_id, r.images, now()
    from tmp_pancake_products_resolved r
    where not r.was_existing
    returning 1
  )
  select count(*) into v_count from ins;
  v_items_inserted := v_count;

  select count(*) into v_items_synced from tmp_pancake_products_resolved;

  ------------------------------------------------------------------------------------
  -- Phase 2: Variants <- /products/variations (one row per variation, linked back to
  -- the Items row it belongs to - same ProductId-then-Code match precedence as Phase 1).
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
  -- ProductId (Pancake's own stable id) only, falling back to an exact Code match - see the
  -- BUGFIX header comment above for why SKU is no longer used as a match key here either.
  left join lateral (
    select coalesce(
      (select i."Code" from public."Items" i where t.product_id is not null and i."ProductId" = t.product_id limit 1),
      (select i."Code" from public."Items" i where i."Code" = t.main_item_code limit 1)
    ) as matched_code
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

-- No grant to anon - called directly by pg_cron inside Postgres, never through PostgREST. The
-- existing "*/5 * * * *" schedule (created in supabase_pancake_manual_sync.sql) calls this
-- function by name and needs no changes - it will pick up this new definition on its next tick.

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
  v_products_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products?api_key=' || public._pancake_api_key();
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

      -- Resolve which existing Items row this product belongs to (ProductId match only, then
      -- Code) - same precedence as admin_sync_items_from_pancake, so a live browse and a full
      -- "Sync Now" both land on the same row instead of accidentally creating duplicates. SKU is
      -- deliberately NOT used here anymore - see the BUGFIX comment in
      -- admin_sync_items_from_pancake (supabase_pancake_item_sku_match_fix.sql) for why: a
      -- non-unique fallback value that was silently merging unrelated rows together.
      select coalesce(
        (select i."Code" from public."Items" i where v_product_id is not null and i."ProductId" = v_product_id limit 1),
        (select i."Code" from public."Items" i where i."Code" = v_code limit 1)
      ) into v_matched_code;

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
