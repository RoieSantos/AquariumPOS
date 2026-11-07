-- Online Orders -> New: "+ New Order" with no Facebook customer. Per "can we build an new order on the online
-- order even though there is no facebook customer tagged on it".
--
-- Until now the only staff "+ New Order" was GMA Conversations (admin_create_gma_conversation_order), which
-- refuses an order without a Psid. This adds:
--   1. admin_create_portal_order - same as the GMA one minus the Psid / Page: saves the AO- order as
--      'Not Pushed' (UpdatedBy = the staff user), so it lands on the New tab and staff Confirm Order like any
--      other. Customer name is required; phone is optional (validated when given) - "CustomerPhone" is NOT
--      NULL, so no phone is stored as ''. No Pancake push. No Messenger messages can ever go out for it
--      (no Psid) - Confirm Order / Xendit auto-confirm already skip the message when there's no Psid.
--   2. admin_update_automated_order (Edit on the New tab / GMA Edit Order): phone may stay blank, but only on
--      an order with no Facebook customer (no GmaPsid). Patched into the LIVE function text, so the latest
--      version (supabase_custom_aquarium_part_revenue.sql) is kept. If that file - or any older file that
--      redefines admin_update_automated_order - is re-run later, run this one again afterwards.
--
-- Run AFTER supabase_custom_aquarium_part_revenue.sql. Safe to re-run. Ends with one result query.
-- Needs js/onlineNewOrders.js ?v=newnocust1.

-- ---------------------------------------------------------------------------
-- 1. admin_create_portal_order

create or replace function public.admin_create_portal_order(
  p_admin_username text,
  p_admin_password text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_lines jsonb,
  p_delivery_fee numeric default null
)
returns table(order_no text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '90000'
as $$
declare
  v_order_no text;
  v_phone text := coalesce(trim(p_customer_phone), '');
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
  v_delivery_fee numeric(18, 2);
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if v_phone <> '' and regexp_replace(v_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Please provide a valid PH mobile number, e.g. 09171234567 (or leave it blank).';
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
  if coalesce(p_delivery_fee, 0) < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;
  v_delivery_fee := case when v_fulfillment = 'Delivery' then round(coalesce(p_delivery_fee, 0), 2) else 0 end;

  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');

  insert into public."AutomatedOrders"
    ("OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status",
     "EstimatedTotal", "Location", "GmaPsid", "GmaPageId", "UpdatedBy", "PancakeSyncStatus", "DeliveryFee")
  values
    (v_order_no, trim(p_customer_name), v_phone, nullif(trim(coalesce(p_customer_email, '')), ''),
     v_fulfillment, case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
     nullif(trim(coalesce(p_notes, '')), ''), 'New', 0, v_location, null, null, p_admin_username, 'Not Pushed',
     v_delivery_fee);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);
    v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price", "Notes", "VariationId")
    values
      (v_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price,
       left(nullif(trim(coalesce(v_line->>'note', '')), ''), 2000), nullif(trim(coalesce(v_line->>'variation_id', '')), ''));

    v_total := v_total + (v_qty * v_price);
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total + v_delivery_fee where "OrderNo" = v_order_no;

  -- No Pancake push - staff confirm it into Online Orders with "Confirm Order" (admin_confirm_bot_order).
  return query select v_order_no;
end;
$$;

grant execute on function public.admin_create_portal_order(text, text, text, text, text, text, text, text, text, jsonb, numeric) to anon;

-- ---------------------------------------------------------------------------
-- 2. admin_update_automated_order: blank phone allowed when the order has no Facebook customer.
--    Stops with an error, without changing the function, if the expected text isn't there.

do $patch$
declare
  v_sig regprocedure := 'public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb, numeric)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_new text;
begin
  if v_def like '%supabase_online_orders_new_order_no_customer.sql%' then
    raise notice 'admin_update_automated_order already patched - skipped.';
    return;
  end if;

  v_new := replace(v_def,
    $s$  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
  if regexp_replace(p_customer_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Please provide a valid PH mobile number, e.g. 09171234567.';
  end if;$s$,
    $s$  -- supabase_online_orders_new_order_no_customer.sql: phone may be blank on an order with no Facebook customer.
  if coalesce(trim(p_customer_phone), '') = '' then
    if exists (select 1 from public."AutomatedOrders" x
                where x."OrderNo" = p_order_no and nullif(trim(coalesce(x."GmaPsid", '')), '') is not null) then
      raise exception 'Customer phone number is required.';
    end if;
  elsif regexp_replace(p_customer_phone, '[^0-9]', '', 'g') !~ '^(09[0-9]{9}|639[0-9]{9})$' then
    raise exception 'Please provide a valid PH mobile number, e.g. 09171234567.';
  end if;$s$);
  if v_new = v_def then raise exception 'admin_update_automated_order patch: phone check not found - nothing changed.'; end if;

  v_new := replace(v_new,
    $s$"CustomerPhone" = trim(p_customer_phone),$s$,
    $s$"CustomerPhone" = coalesce(trim(p_customer_phone), ''),$s$);

  execute v_new;
end
$patch$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
select 'admin_create_portal_order exists' as check_name,
       (to_regprocedure('public.admin_create_portal_order(text, text, text, text, text, text, text, text, text, jsonb, numeric)') is not null)::text as result
union all
select 'admin_update_automated_order allows blank phone (no Facebook customer)',
       (pg_get_functiondef('public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb, numeric)'::regprocedure)
          like '%supabase_online_orders_new_order_no_customer.sql%')::text;
