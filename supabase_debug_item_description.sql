-- One-off debug helper for tracking down why a specific item's Description isn't picking up
-- Pancake's note_product (see supabase_pancake_manual_sync.sql's admin_sync_items_from_pancake/
-- cron_sync_items_from_pancake) - pages through /products the SAME way those functions do,
-- looking for the product whose resolved code matches p_item_code, and returns:
--   - what's currently stored in public."Items" for that code right now
--   - the note_product value the sync would have extracted from Pancake's raw response
--   - the FULL raw product JSON, so a shape mismatch (e.g. a combo/SET product nesting
--     note_product somewhere other than the top level) is visible directly instead of guessed at
--
-- Usage: run this file once to create the function, then:
--   select * from public.debug_item_description('100GALLONS-AQUARIUM-6MM');
-- Swap in whichever Items.Code you want to inspect. Safe to re-run - read-only, no writes.

drop function if exists public.debug_item_description(text);

create or replace function public.debug_item_description(p_item_code text)
returns table(
  current_description text,
  current_sku text,
  current_product_id text,
  current_synced_at_utc timestamptz,
  matched_on_pancake boolean,
  extracted_note_product text,
  raw_product jsonb
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_products_url text := 'https://pos.pages.fm/api/v1/shops/1328301944/products?api_key=' || public._pancake_api_key();
  v_page int := 1;
  v_max_pages int := 100;
  v_page_size int := 200;
  v_response extensions.http_response;
  v_body jsonb;
  v_page_items jsonb;
  v_product jsonb;
  v_resolved_code text;
  v_found jsonb := null;
begin
  select i."Description", i."SKU", i."ProductId", i."SyncedAtUtc"
    into current_description, current_sku, current_product_id, current_synced_at_utc
  from public."Items" i
  where i."Code" = p_item_code;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '45000');

  while v_page <= v_max_pages and v_found is null loop
    v_response := extensions.http_get(v_products_url || '&page=' || v_page || '&pagesize=' || v_page_size);
    exit when v_response.status < 200 or v_response.status >= 300;

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
      v_resolved_code := coalesce(
        nullif(v_product ->> 'custom_id', ''),
        nullif(v_product -> 'variations' -> 0 ->> 'display_id', ''),
        nullif(v_product ->> 'code', ''),
        nullif(v_product ->> 'sku', ''),
        nullif(v_product ->> 'display_id', ''),
        v_product ->> 'id'
      );
      if v_resolved_code = p_item_code then
        v_found := v_product;
        exit;
      end if;
    end loop;

    v_page := v_page + 1;
  end loop;

  matched_on_pancake := v_found is not null;
  raw_product := v_found;
  extracted_note_product := nullif(v_found ->> 'note_product', '');

  return next;
end;
$$;

grant execute on function public.debug_item_description(text) to anon;
