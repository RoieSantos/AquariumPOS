-- Security fix: submit_automated_order (supabase_automated_orders_tables.sql) is granted to
-- `anon` (it has to be - it's the public Order Now page's only write path, no login) and, until
-- now, trusted whatever "price" each line's JSON payload claimed. js/orderNow.js always sends the
-- real catalog price for a "Standard flow" line (see its addToCart handler - price comes straight
-- from public_list_order_items' own return value), but nothing stopped a caller from calling this
-- RPC directly (the anon key is public by design, and the RPC itself is a plain, callable
-- Postgres function - no CAPTCHA/signature/session ties the request to the page) with a doctored
-- price - e.g. quantity 1, price 1.00 for a real item that costs 15,000. That fabricated price was
-- stored on AutomatedOrderLines and then pushed VERBATIM into a real Pancake order by
-- _push_automated_order_to_pancake (its "retail_price" comes straight from
-- AutomatedOrderLines."Price") - a genuine, exploitable price-tampering hole with real financial
-- impact, not just a display glitch.
--
-- Fix: whenever a line carries a real catalog item_code, look up that item's own
-- Items.RetailPrice/Price server-side and use THAT instead of the client-submitted price -
-- exactly the same Code-match _push_automated_order_to_pancake already relies on to find the
-- Pancake product, just applied here too so the two can never disagree. A line with a
-- recognized-but-inactive/nonexistent item_code is now rejected outright instead of silently
-- accepting an arbitrary price for it.
--
-- Residual gap (documented, not fixed here - would need the entire pricing calculator
-- reimplemented in SQL): the Customize flow's Custom Aquarium / Custom Stand / Custom Filtration
-- lines have no catalog item_code at all (they're one-off calculated quotes - see
-- js/orderNow.js's buildCustomAquariumLine etc., itemCode: null) so there's no server-side price
-- to check them against; those lines still trust the client-submitted price. Tightening that
-- further (e.g. plausibility bounds, or flagging suspicious combinations for staff review before
-- the Pancake push) would need a separate follow-up.
drop function if exists public.submit_automated_order(text, text, text, text, text, text, text, text, jsonb);

create or replace function public.submit_automated_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_psid text,
  p_lines jsonb
)
returns table(order_no text, pancake_order_id text, pancake_sync_status text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_psid text := nullif(trim(coalesce(p_psid, '')), '');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
  v_item_code text;
  v_line_count int := 0;
begin
  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
  -- The real gate (js/orderNow.js's isValidPhMobileNumber does the same check client-side, but
  -- that's only a UX nicety - this is what actually stops junk like "test" from reaching
  -- AutomatedOrders/Pancake, since Pancake's own order API rejects it with an unhelpfully empty
  -- 422 error rather than a clear validation message). Accepts PH mobile numbers in local
  -- (09171234567), country-code (639171234567), or +-prefixed (+639171234567) form.
  if regexp_replace(p_customer_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Please provide a valid PH mobile number, e.g. 09171234567.';
  end if;
  if v_fulfillment not in ('Pickup', 'Delivery') then
    raise exception 'Fulfillment type must be Pickup or Delivery.';
  end if;
  if v_fulfillment = 'Delivery' and (p_delivery_address is null or trim(p_delivery_address) = '') then
    raise exception 'Delivery address is required for delivery orders.';
  end if;
  if v_location not in ('Amaya', 'GMA') then
    raise exception 'Location must be Amaya or GMA.';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one item is required.';
  end if;

  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');

  insert into public."AutomatedOrders"
    ("OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status", "EstimatedTotal", "Location", "Psid")
  values
    (v_order_no, trim(p_customer_name), trim(p_customer_phone), nullif(trim(coalesce(p_customer_email, '')), ''),
     v_fulfillment, case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
     nullif(trim(coalesce(p_notes, '')), ''), 'New', 0, v_location, v_psid);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    -- Security fix (see file header): a real catalog item_code always gets its price looked up
    -- server-side, never taken from the client. Only a line with no item_code at all (a
    -- Customize-flow calculated quote) falls back to the client-submitted price.
    v_item_code := nullif(trim(coalesce(v_line->>'item_code', '')), '');
    if v_item_code is not null then
      select coalesce(i."RetailPrice", i."Price", 0) into v_price
      from public."Items" i
      where i."Code" = v_item_code
        and i."IsActive" is true;

      if not found then
        raise exception 'Item % is not a recognized catalog item.', v_item_code;
      end if;
    else
      v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price")
    values
      (v_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       v_item_code, trim(v_line->>'item_name'), v_qty, v_price);

    v_total := v_total + (v_qty * v_price);
    v_line_count := v_line_count + 1;
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = v_order_no;

  perform public._push_automated_order_to_pancake(v_order_no);
  -- Runs after the Pancake push (not before) so the confirmation message can include the real
  -- Pancake order number when the push succeeded. Same never-raises contract as the push itself -
  -- see _send_order_confirmation_message's own comment above.
  perform public._send_order_confirmation_message(v_order_no);

  -- _push_automated_order_to_pancake always resolves to Synced/Failed on this same row before
  -- returning (it's called synchronously, not fired off in the background), so PancakeOrderId is
  -- already whatever it's going to be by this point - the confirmation screen (js/orderNow.js)
  -- uses it in place of the internal OrderNo when available, falling back to OrderNo otherwise.
  return query
    select o."OrderNo"::text, o."PancakeOrderId"::text, o."PancakeSyncStatus"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = v_order_no;
end;
$$;

grant execute on function public.submit_automated_order(text, text, text, text, text, text, text, text, jsonb) to anon;
