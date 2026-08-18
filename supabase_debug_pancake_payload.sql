-- One-off debug helper: rebuilds the EXACT same Pancake order payload/URL that
-- _push_automated_order_to_pancake() would send for a given AutomatedOrders."OrderNo" -
-- but does NOT call http_post, so it's safe to run repeatedly without creating duplicate
-- Pancake orders. Mirrors that function's logic line-for-line (see
-- supabase_automated_orders_tables.sql) so what you see here is really what would be/was sent.
--
-- Usage: run this file once to create the function, then:
--   select * from public.debug_automated_order_pancake_payload('AO-00003');
-- Swap in whichever OrderNo you want to inspect.

drop function if exists public.debug_automated_order_pancake_payload(text);

create or replace function public.debug_automated_order_pancake_payload(p_order_no text)
returns table(url text, payload jsonb, matched_count int, line_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_shop_id text := '1328301944';
  v_api_key text := 'e611861d2fc84607bfbbe1428a432447';
  v_page_id text := '195716644410829';
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_location text;
  v_warehouse_id text;
  v_line_count int;
  v_items_json jsonb;
  v_matched_count int;
  v_customer_id text;
  v_conversation_id text;
  v_shipping_json jsonb;
  v_payload jsonb;
  v_url text;
  v_lines_note text;
begin
  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;

  v_location := coalesce(nullif(trim(v_order."Location"), ''), 'Amaya');

  select "ID" into v_warehouse_id
  from public."Warehouses"
  where "Name" ilike '%' || v_location || '%'
  order by "Name"
  limit 1;

  select count(*) into v_line_count from public."AutomatedOrderLines" where "OrderNo" = p_order_no;

  select string_agg(l."ItemName" || ' x' || l."Quantity" || ' @ ' || l."Price", E'\n' order by l."EntryNo")
  into v_lines_note
  from public."AutomatedOrderLines" l
  where l."OrderNo" = p_order_no;

  select
    jsonb_agg(
      jsonb_build_object(
        'variation_id', i."VariationId",
        'product_id', i."ProductId",
        'quantity', l."Quantity",
        'note', l."ItemName",
        'note_product', l."ItemName",
        'variation_info', jsonb_build_object(
          'id', i."VariationId",
          'product_id', i."ProductId",
          'name', l."ItemName",
          'retail_price', round(l."Price")::int
        )
      )
    ),
    count(*)
  into v_items_json, v_matched_count
  from public."AutomatedOrderLines" l
  join public."Items" i
    on i."Code" = coalesce(nullif(l."ItemCode", ''), nullif(l."CategoryCode", ''))
    or (l."ItemCode" is null and i."Name" = nullif(l."CategoryCode", ''))
  where l."OrderNo" = p_order_no
    and (i."VariationId" is not null or i."ProductId" is not null);

  if v_order."Psid" is not null then
    v_conversation_id := v_page_id || '_' || v_order."Psid";

    select "CustomerID" into v_customer_id
    from public."OnlineCustomers"
    where "FbID" = v_order."Psid" or "FbID" = v_conversation_id
    limit 1;
  end if;

  v_shipping_json := case when v_order."FulfillmentType" = 'Delivery' then
    jsonb_build_object(
      'address', v_order."DeliveryAddress",
      'full_address', v_order."DeliveryAddress",
      'full_name', v_order."CustomerName",
      'phone_number', v_order."CustomerPhone"
    )
  else null end;

  v_payload := jsonb_build_object(
    'shop_id', v_shop_id,
    'warehouse_id', v_warehouse_id,
    'bill_full_name', v_order."CustomerName",
    'bill_phone_number', v_order."CustomerPhone",
    'bill_email', v_order."CustomerEmail",
    'page_id', v_page_id,
    'items', v_items_json,
    'note', 'Web order ' || p_order_no
      || coalesce(E'\n' || v_lines_note, '')
      || coalesce(' | Customer note: ' || nullif(trim(v_order."Notes"), ''), ''),
    'is_free_shipping', false,
    'shipping_fee', 0,
    'status', 0
  )
    || case when v_customer_id is not null then jsonb_build_object('customer_id', v_customer_id) else '{}'::jsonb end
    || case when v_conversation_id is not null then jsonb_build_object('conversation_id', v_conversation_id) else '{}'::jsonb end
    || case when v_shipping_json is not null then jsonb_build_object('shipping_address', v_shipping_json) else '{}'::jsonb end;

  v_url := v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key;

  return query select v_url, v_payload, v_matched_count, v_line_count;
end;
$$;

-- Not granted to anon directly - the URL it returns embeds the live Pancake shop API key, so it
-- must stay behind staff auth. Run directly in the Supabase SQL editor, OR use the staff-gated
-- wrapper below (used by the "View Endpoint & Payload" button on the Automated Orders staff page,
-- docs/automated-orders.html / js/automatedOrders.js).

drop function if exists public.admin_debug_automated_order_pancake_payload(text, text, text);

create or replace function public.admin_debug_automated_order_pancake_payload(
  p_admin_username text,
  p_admin_password text,
  p_order_no text
)
returns table(url text, payload jsonb, matched_count int, line_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query select * from public.debug_automated_order_pancake_payload(p_order_no);
end;
$$;

grant execute on function public.admin_debug_automated_order_pancake_payload(text, text, text) to anon;
