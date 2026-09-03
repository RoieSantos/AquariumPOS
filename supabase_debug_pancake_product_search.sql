-- One-off debug helper: walks Pancake's /products endpoint page-by-page (same pagination logic
-- as admin_sync_items_from_pancake/cron_sync_items_from_pancake - see supabase_pancake_manual_
-- sync.sql) looking for one product whose custom_id/code/sku/display_id/id/name matches
-- p_search, and returns that product's RAW json exactly as Pancake sent it, plus which page it
-- was found on. If nothing matches, returns null (raw_product) and how many pages were walked
-- before giving up - that distinguishes "Pancake genuinely never returns this product" from "our
-- own sync logic is dropping/misrouting it after receiving it".
--
-- Per direct investigation: a newly-added product (PI-037, no variants) synced with
-- cron_sync_items_from_pancake() reporting SUCCESS, but never showed up in public."Items". This
-- lets us see its actual shape (or confirm Pancake never returns it at all) instead of guessing.
--
-- Usage: run this file once, then:
--   select * from public.debug_find_pancake_product('PI-037');
-- Not granted to anon - embeds the live Pancake API key in the URLs it calls, same as
-- debug_automated_order_pancake_payload (supabase_debug_pancake_payload.sql). Run directly in
-- the Supabase SQL editor.
drop function if exists public.debug_find_pancake_product(text, int);

create or replace function public.debug_find_pancake_product(p_search text, p_max_pages int default 500)
returns table(found_on_page int, pages_searched int, raw_product jsonb)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_products_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products?api_key=' || public._pancake_api_key();
  v_page int := 1;
  v_max_pages int := least(greatest(coalesce(p_max_pages, 500), 1), 500);
  v_response extensions.http_response;
  v_body jsonb;
  v_page_items jsonb;
  v_product jsonb;
  v_match jsonb;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '45000');

  while v_page <= v_max_pages loop
    v_response := extensions.http_get(v_products_url || '&page=' || v_page || '&pagesize=200');

    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake products request failed (HTTP %) on page %.', v_response.status, v_page;
    end if;

    v_body := v_response.content::jsonb;
    v_page_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'products') = 'array' then v_body -> 'products'
      else '[]'::jsonb
    end;

    exit when jsonb_typeof(v_page_items) <> 'array' or jsonb_array_length(v_page_items) = 0;

    for v_product in select * from jsonb_array_elements(v_page_items)
    loop
      if coalesce(v_product ->> 'custom_id', '') ilike '%' || p_search || '%'
        or coalesce(v_product ->> 'code', '') ilike '%' || p_search || '%'
        or coalesce(v_product ->> 'sku', '') ilike '%' || p_search || '%'
        or coalesce(v_product ->> 'display_id', '') ilike '%' || p_search || '%'
        or coalesce(v_product ->> 'id', '') ilike '%' || p_search || '%'
        or coalesce(v_product ->> 'name', '') ilike '%' || p_search || '%'
        or coalesce(v_product -> 'variations' -> 0 ->> 'display_id', '') ilike '%' || p_search || '%'
      then
        v_match := v_product;
        return query select v_page, v_page, v_match;
        return;
      end if;
    end loop;

    v_page := v_page + 1;
  end loop;

  return query select null::int, v_page - 1, null::jsonb;
end;
$$;

-- Follow-up: breaks the found product down into exactly the fields
-- admin_sync_items_from_pancake's Phase 1 actually reads (see the "code"/"sku"/"price"/
-- "category" derivation in supabase_pancake_manual_sync.sql), so we can see precisely what the
-- sync would have computed for it and where it resolves (or fails to resolve) an existing
-- Items row - without eyeballing a giant raw JSON blob in the results grid.
drop function if exists public.debug_explain_pancake_product_sync(text);

create or replace function public.debug_explain_pancake_product_sync(p_search text)
returns table(
  resolved_code text,
  resolved_sku text,
  resolved_name text,
  resolved_price numeric,
  resolved_category text,
  resolved_product_id text,
  has_variations boolean,
  variations_count int,
  categories_raw jsonb,
  matched_existing_items_code text,
  raw_top_level_keys text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_product jsonb;
  v_sku text;
begin
  select raw_product into v_product from public.debug_find_pancake_product(p_search) where raw_product is not null limit 1;

  if v_product is null then
    raise exception 'No Pancake product matched % - see debug_find_pancake_product for pages_searched.', p_search;
  end if;

  resolved_code := coalesce(
    nullif(v_product ->> 'custom_id', ''),
    nullif(v_product -> 'variations' -> 0 ->> 'display_id', ''),
    nullif(v_product ->> 'code', ''),
    nullif(v_product ->> 'sku', ''),
    nullif(v_product ->> 'display_id', ''),
    v_product ->> 'id'
  );

  v_sku := coalesce(nullif(v_product -> 'variations' -> 0 ->> 'display_id', ''), nullif(v_product ->> 'display_id', ''));
  resolved_sku := v_sku;

  resolved_name := v_product ->> 'name';

  resolved_price := public.try_parse_numeric(coalesce(
    nullif(v_product -> 'variations' -> 0 ->> 'retail_price', ''),
    nullif(v_product ->> 'retail_price', ''),
    v_product ->> 'price'
  ));

  resolved_category := public.try_extract_first_category(v_product);
  resolved_product_id := nullif(v_product ->> 'id', '');

  has_variations := jsonb_typeof(v_product -> 'variations') = 'array' and jsonb_array_length(v_product -> 'variations') > 0;
  variations_count := case when jsonb_typeof(v_product -> 'variations') = 'array' then jsonb_array_length(v_product -> 'variations') else 0 end;

  categories_raw := v_product -> 'categories';

  select i."Code" into matched_existing_items_code
  from public."Items" i
  where (v_sku is not null and i."SKU" = v_sku) or i."Code" = resolved_code
  order by (i."SKU" = v_sku) desc nulls last
  limit 1;

  select string_agg(k, ', ') into raw_top_level_keys from jsonb_object_keys(v_product) k;

  return next;
end;
$$;
