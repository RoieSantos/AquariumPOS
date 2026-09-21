-- Makes prices editable from Item Setup and pushes them to Pancake, per direct decision that the
-- portal is where prices get changed and Pancake is the hub everything else reads from:
--
--   Portal (these RPCs) -> Pancake (PUT retail_price) -> local POS (its own 5-minute
--   SyncProductVariationsAsync pull, MainForm.MasterDataSyncTimer_Tick) -> Supabase (POS push).
--
-- Nothing on the POS side needs changing - it already pulls Pancake's retail_price into
-- dbo.Items.Price / dbo.Variant.Price - so the local POS picks the new price up within one timer tick
-- of a terminal being online.
--
-- Prices live PER VARIANT in Pancake (each variation has its own retail_price), so:
--   admin_set_variant_price  the general case - one specific variation, by VariationId.
--   admin_set_item_price     convenience for items with 0 or 1 variants (resolves the one variation
--                            itself). Refused for items with several variants - there is no single
--                            "item price" to push, the caller must pick a variant.
--
-- Pancake goes FIRST, the portal second: if Pancake rejects the update, nothing changes here and the
-- caller gets Pancake's error. Writing locally first would leave the portal showing a price that the
-- next Pancake sync (which overwrites Variants/Items.Price with coalesce(pancake_price, Price))
-- silently reverts - the exact problem this whole flow exists to fix.
--
-- Endpoint (Pancake POS Open API, "Updating a Product"): PUT /shops/{shop}/products/{product_id}
-- with { product: { variations: [{ id, retail_price, price_at_counter }] } } - a variation with an id is
-- UPDATED and variations left out of the array are untouched, so only the one variant changes.
-- price_at_counter is sent alongside retail_price because that is what the desktop's product create
-- (SyncUpProductsAsync) always sets them to together; retail_price is the one the POS/portal sync
-- actually reads.
--
-- Items.Price for an item with variants is a copy of ONE representative variant's price (the sync's
-- variant_item_link picks it and stores that variant's id in Items.VariationId - see
-- supabase_pancake_manual_sync.sql), so editing a variant also updates Items.Price when - and only
-- when - that variant is the representative one. Otherwise Items.Price would drift from what the next
-- sync writes.

drop function if exists public._pancake_push_variation_price(text, text, numeric);

-- Internal: the Pancake PUT, shared by both RPCs below. Deliberately NOT granted to anon/authenticated
-- (same as public._pancake_api_key) - only the SECURITY DEFINER RPCs below call it, after their own
-- admin check. Returns jsonb { price, confirmed }:
--   price      what Pancake says the variation's price is now when it echoes one (it is the master,
--              so if it rounded or ignored the value the portal follows it), else what was sent
--   confirmed  true when Pancake's response actually included this variation's price to check
create or replace function public._pancake_push_variation_price(
  p_product_id text,
  p_variation_id text,
  p_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  -- Whole number, sent as a JSON integer: a first live try with 2-decimal values (150.00) got HTTP 422
  -- "[retail_price]: is invalid; [price_at_counter]: is invalid". Pancake's own order-line prices are
  -- whole numbers too (round(...)::int elsewhere in this repo), and an integer is accepted whether the
  -- field is validated as an integer or a decimal. Fractional pesos are therefore rounded here; the RPCs
  -- return the rounded price as "price" (and the unrounded ask as "requested") so the UI can say so.
  v_price numeric := round(p_price);
  v_url text;
  v_body jsonb;
  v_response extensions.http_response;
  v_response_body jsonb;
  v_returned_price numeric;
begin
  if v_api_key is null or trim(v_api_key) = '' then
    raise exception 'The Pancake API key is not configured - set it in General Setup > Secure API Keys first.';
  end if;

  v_url := v_base_url || '/shops/' || v_shop_id || '/products/' || p_product_id || '?api_key=' || v_api_key;
  v_body := jsonb_build_object(
    'product', jsonb_build_object(
      'variations', jsonb_build_array(
        jsonb_build_object(
          'id', p_variation_id,
          'retail_price', v_price::bigint,
          'price_at_counter', v_price::bigint
        )
      )
    )
  );

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  perform extensions.http_set_curlopt('CURLOPT_USERAGENT', 'RSPetStopPortal/1.0');

  select * into v_response from extensions.http((
    'PUT',
    v_url,
    array[
      extensions.http_header('Accept', 'application/json'),
      extensions.http_header('Expect', '')
    ],
    'application/json',
    v_body::text
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    -- The body is included (it carries no secret - the api_key is only in the URL) so a rejected
    -- payload can be diagnosed from the message alone.
    raise exception 'Pancake rejected the price update (HTTP %): % | sent: %', v_response.status, left(v_response.content, 300), left(v_body::text, 300);
  end if;

  -- Best-effort read of what Pancake says the variation's price is now. Pancake can answer 200 with
  -- success = false, and the response shape isn't guaranteed to echo variations at all, so a missing
  -- price just means "unconfirmed" - only an explicit failure flag or a returned price is acted on.
  begin
    v_response_body := v_response.content::jsonb;
  exception when others then
    v_response_body := null;
  end;

  if v_response_body is not null and jsonb_typeof(v_response_body) = 'object'
     and (v_response_body ->> 'success') = 'false' then
    raise exception 'Pancake rejected the price update: %', left(v_response.content, 300);
  end if;

  if v_response_body is not null then
    begin
      select nullif(e ->> 'retail_price', '')::numeric into v_returned_price
      from jsonb_path_query(
        v_response_body,
        '$.**.variations[*] ? (@.id == $vid)',
        jsonb_build_object('vid', p_variation_id)
      ) as e
      limit 1;
    exception when others then
      v_returned_price := null;
    end;
  end if;

  return jsonb_build_object(
    'price', coalesce(v_returned_price, v_price),
    'confirmed', v_returned_price is not null
  );
end;
$$;

revoke all on function public._pancake_push_variation_price(text, text, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- admin_set_variant_price: one specific variation.
-- Returns jsonb { price, requested, pancake_confirmed, item_price_updated }.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_set_variant_price(text, text, text, numeric);

create or replace function public.admin_set_variant_price(
  p_admin_username text,
  p_admin_password text,
  p_variation_id text,
  p_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_variant public."Variants"%rowtype;
  v_price numeric;
  v_product_id text;
  v_result jsonb;
  v_final_price numeric;
  v_items_updated int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_price is null or p_price < 0 then
    raise exception 'Price must be 0 or more.';
  end if;
  v_price := round(p_price, 2);

  select * into v_variant from public."Variants" where "VariationId" = p_variation_id;
  if not found then
    raise exception 'Variant % not found.', p_variation_id;
  end if;

  v_product_id := nullif(trim(v_variant."ProductId"), '');
  if v_product_id is null then
    select nullif(trim(i."ProductId"), '') into v_product_id
      from public."Items" i
      where i."Code" = coalesce(nullif(v_variant."ItemCode", ''), v_variant."MainItemCode");
  end if;

  if v_product_id is null then
    raise exception 'This variant is not linked to a Pancake product yet (no ProductId) - run the Pancake sync first, then try again.';
  end if;

  v_result := public._pancake_push_variation_price(v_product_id, p_variation_id, v_price);
  v_final_price := (v_result ->> 'price')::numeric;

  update public."Variants" set "Price" = v_final_price where "VariationId" = p_variation_id;

  -- Only the representative variant's edit reaches Items.Price - see the header comment.
  update public."Items" set "Price" = v_final_price where "VariationId" = p_variation_id;
  get diagnostics v_items_updated = row_count;

  return jsonb_build_object(
    'price', v_final_price,
    'requested', v_price,
    'pancake_confirmed', (v_result ->> 'confirmed')::boolean,
    'item_price_updated', v_items_updated > 0
  );
end;
$$;

grant execute on function public.admin_set_variant_price(text, text, text, numeric) to anon;

-- ---------------------------------------------------------------------------
-- admin_set_item_price: items with 0 or 1 variants (Item Setup's Price box).
-- Returns jsonb { price, requested, pancake_confirmed, retail_price_override }:
--   retail_price_override Items."RetailPrice" when it is set and differs from the new price, else
--                         null. Order Now, the AI bot and order price validation all quote
--                         coalesce("RetailPrice", "Price"), so a stale RetailPrice would win over
--                         the price just saved - the caller should tell the user.
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_item_price(
  p_admin_username text,
  p_admin_password text,
  p_item_code text,
  p_price numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '30000'
as $$
declare
  v_item public."Items"%rowtype;
  v_price numeric;
  v_variant_count int;
  v_variation_id text;
  v_product_id text;
  v_result jsonb;
  v_final_price numeric;
  v_retail_override numeric;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_price is null or p_price < 0 then
    raise exception 'Price must be 0 or more.';
  end if;
  v_price := round(p_price, 2);

  select * into v_item from public."Items" where "Code" = p_item_code;
  if not found then
    raise exception 'Item % not found.', p_item_code;
  end if;

  -- Same lookup the Item Card's Variants tab uses (Variants.MainItemCode = this item's code).
  select count(*) into v_variant_count from public."Variants" where "MainItemCode" = p_item_code;

  if v_variant_count > 1 then
    raise exception 'This item has % variants, each with its own price - set the price on the variant instead (Item Card > Variants).', v_variant_count;
  end if;

  if v_variant_count = 1 then
    select nullif(trim("VariationId"), ''), nullif(trim("ProductId"), '')
      into v_variation_id, v_product_id
      from public."Variants" where "MainItemCode" = p_item_code;
  end if;

  v_variation_id := coalesce(v_variation_id, nullif(trim(v_item."VariationId"), ''));
  v_product_id := coalesce(v_product_id, nullif(trim(v_item."ProductId"), ''));

  if v_product_id is null and v_variation_id is not null then
    select nullif(trim("ProductId"), '') into v_product_id
      from public."Variants" where "VariationId" = v_variation_id;
  end if;

  if v_variation_id is null or v_product_id is null then
    raise exception 'This item is not linked to a Pancake product yet (no VariationId/ProductId) - run the Pancake sync first, then try again.';
  end if;

  v_result := public._pancake_push_variation_price(v_product_id, v_variation_id, v_price);
  v_final_price := (v_result ->> 'price')::numeric;

  update public."Items" set "Price" = v_final_price where "Code" = p_item_code;
  update public."Variants" set "Price" = v_final_price where "VariationId" = v_variation_id;

  if v_item."RetailPrice" is not null and v_item."RetailPrice" <> v_final_price then
    v_retail_override := v_item."RetailPrice";
  end if;

  return jsonb_build_object(
    'price', v_final_price,
    'requested', v_price,
    'pancake_confirmed', (v_result ->> 'confirmed')::boolean,
    'retail_price_override', v_retail_override
  );
end;
$$;

grant execute on function public.admin_set_item_price(text, text, text, numeric) to anon;
