-- Online Orders: SKU per line on the order card - per "in the online order lines can you show the SKU too".
--
-- admin_get_online_order_detail_live (the order card's Lines, read live from Pancake) gains a `sku`
-- column: the line's variant SKU (Variants."SKU" by its variation id), else the item's SKU
-- (Items."SKU"), else the Item Code. (No "any variant of the item" fallback - on an item with several
-- variants that could show another variant's SKU.)
-- Same body as supabase_walkin_order_pos_description.sql otherwise. The return type changes, so the
-- function is dropped first; the page shows the Item Code in the SKU column until this is run.
-- Re-running supabase_walkin_order_pos_description.sql would drop the sku column again - run this after it.

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
  note text,
  order_note text,
  sku text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_detail_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_order_el jsonb;
  v_status_raw text;
  v_status text;
  v_customer text;
  v_order_note text;
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

  -- Order-level note: for walk-ins, the POS receipt description (see header comment).
  v_order_note := nullif(trim(coalesce(v_order_el ->> 'note', '')), '');

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
      order_note := v_order_note;
      sku := coalesce(
        (select nullif(trim(v."SKU"), '') from public."Variants" v
          where v."VariationId" = nullif(v_variation_id, '') and nullif(trim(v."SKU"), '') is not null limit 1),
        (select nullif(trim(i."SKU"), '') from public."Items" i
          where i."Code" = v_product_display_id and nullif(trim(i."SKU"), '') is not null limit 1),
        v_product_display_id
      );
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
    order_note := v_order_note;
    sku := null;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_get_online_order_detail_live(text, text, text) to anon;
