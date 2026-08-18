-- Live "available at From Warehouse" stock for a Transfer Order's lines, read straight from
-- Pancake Cloud (pos.pages.fm) at Manage-modal-open time - per direct request ("show the
-- available in stock based on the pancake endpoint... it should be on /products/{Product}...
-- under variations_warehouse.remain quantity... per warehouse per variant").
--
-- Unlike GetCloudVariationAvailableQuantityForWarehouseAsync (OnlinefunctionsEvents.cs), which
-- calls GET /shops/{id}/variations/{variationId} once per variant, this calls GET
-- /shops/{id}/products/{productId} once per DISTINCT product referenced by the order (cached in
-- a temp table for the duration of the call) - a product's response nests every one of its
-- variations, each carrying its own "variations_warehouses" array, so one call covers every line
-- on the order that shares that product instead of one call per line.
--
-- Uses the same Pancake base URL/shop id/api key already hardcoded in
-- supabase_transfer_orders_pancake_sync.sql/supabase_pancake_manual_sync.sql.
--
-- Response envelope is handled defensively (confirmed shapes vary by endpoint elsewhere in this
-- codebase - see OnlinefunctionsEvents.cs's GetCloudVariationAvailableQuantityForWarehouseAsync):
-- the product itself may be the raw root, or wrapped under "data"/"product"; "variations" may be
-- missing entirely (fetch_error stays null, remain_quantity stays null - "unknown", not "zero").
--
-- A line with no Variant ID (item has no variants) matches Pancake's own single-variation product
-- shape - GET /products/{id} still returns exactly one entry under "variations" for those, so the
-- same lookup works without a separate code path.

drop function if exists public.staff_get_transfer_line_pancake_stock(text, text, text);

create or replace function public.staff_get_transfer_line_pancake_stock(
  p_admin_username text,
  p_admin_password text,
  p_document_no text
)
returns table(
  line_no bigint,
  item_no text,
  variant_id text,
  remain_quantity numeric,
  fetch_error text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_from_warehouse_id text;
  v_product_id text;
  v_response extensions.http_response;
  v_body jsonb;
  v_product jsonb;
  v_variations jsonb;
  v_variation jsonb;
  v_warehouses jsonb;
  v_wh_entry jsonb;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "From Warehouse ID" into v_from_warehouse_id
  from public."Transfer_Header"
  where "No." = p_document_no;

  create temporary table if not exists tmp_pancake_stock_product_cache (
    product_id text primary key,
    fetch_error text
  );
  create temporary table if not exists tmp_pancake_stock_rows (
    product_id text,
    variation_id text,
    warehouse_id text,
    remain_quantity numeric
  );
  truncate tmp_pancake_stock_product_cache;
  truncate tmp_pancake_stock_rows;

  if v_from_warehouse_id is null or trim(v_from_warehouse_id) = '' then
    -- Nothing to compare against - fall through to the final select, which will return every
    -- line with a null remain_quantity/fetch_error ("unknown" rather than an error).
    return query
      select tl."Line No."::bigint, tl."Item No."::text, tl."Variant ID"::text, null::numeric, null::text
      from public."Transfer_Line" tl
      where tl."Document No." = p_document_no
      order by tl."Line No.";
    return;
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  for v_product_id in
    select distinct coalesce(v."ProductId", i."ProductId")
    from public."Transfer_Line" tl
    left join public."Variants" v on v."VariationId" = tl."Variant ID"
    left join public."Items" i on i."Code" = tl."Item No."
    where tl."Document No." = p_document_no
      and coalesce(v."ProductId", i."ProductId") is not null
      and trim(coalesce(v."ProductId", i."ProductId")) <> ''
  loop
    begin
      select * into v_response from extensions.http_get(
        v_base_url || '/shops/' || v_shop_id || '/products/' || v_product_id || '?api_key=' || v_api_key
      );

      if v_response.status < 200 or v_response.status >= 300 then
        insert into tmp_pancake_stock_product_cache values (v_product_id, 'Pancake returned HTTP ' || v_response.status)
        on conflict (product_id) do nothing;
        continue;
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

      insert into tmp_pancake_stock_product_cache values (v_product_id, null)
      on conflict (product_id) do nothing;

      for v_variation in select * from jsonb_array_elements(v_variations)
      loop
        v_warehouses := case
          when jsonb_typeof(v_variation -> 'variations_warehouses') = 'array' then v_variation -> 'variations_warehouses'
          else '[]'::jsonb
        end;

        for v_wh_entry in select * from jsonb_array_elements(v_warehouses)
        loop
          insert into tmp_pancake_stock_rows values (
            v_product_id,
            coalesce(nullif(v_variation ->> 'id', ''), nullif(v_variation ->> 'variation_id', '')),
            coalesce(nullif(v_wh_entry ->> 'warehouse_id', ''), nullif(v_wh_entry ->> 'warehouseId', '')),
            nullif(coalesce(v_wh_entry ->> 'remain_quantity', v_wh_entry ->> 'remainQuantity', v_wh_entry ->> 'quantity'), '')::numeric
          );
        end loop;
      end loop;
    exception when others then
      insert into tmp_pancake_stock_product_cache values (v_product_id, sqlerrm)
      on conflict (product_id) do nothing;
    end;
  end loop;

  return query
    select
      tl."Line No."::bigint,
      tl."Item No."::text,
      tl."Variant ID"::text,
      (
        select s.remain_quantity
        from tmp_pancake_stock_rows s
        where s.product_id = coalesce(v."ProductId", i."ProductId")
          and s.warehouse_id = v_from_warehouse_id
          and (
            (tl."Variant ID" is not null and trim(tl."Variant ID") <> '' and s.variation_id = tl."Variant ID")
            or tl."Variant ID" is null or trim(tl."Variant ID") = ''
          )
        limit 1
      ) as remain_quantity,
      (
        select c.fetch_error
        from tmp_pancake_stock_product_cache c
        where c.product_id = coalesce(v."ProductId", i."ProductId")
      ) as fetch_error
    from public."Transfer_Line" tl
    left join public."Variants" v on v."VariationId" = tl."Variant ID"
    left join public."Items" i on i."Code" = tl."Item No."
    where tl."Document No." = p_document_no
    order by tl."Line No.";
end;
$$;

grant execute on function public.staff_get_transfer_line_pancake_stock(text, text, text) to anon;
