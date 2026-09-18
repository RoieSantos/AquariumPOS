-- Lets staff modify an AutomatedOrders row (and its lines) after it's already been created - per
-- direct follow-up question ("if the order is created can we modify it still? right now im not sure
-- how to modify created orders"). Until now, AutomatedOrders/AutomatedOrderLines had no update path
-- at all once admin_create_gma_conversation_order/submit_automated_order inserted them - only
-- status (admin_update_automated_order_status), payments (admin_add_automated_order_payment), and
-- the Pancake push itself could be touched afterward.
--
-- Mirrors admin_create_gma_conversation_order's own validation (same customer/fulfillment/lines
-- rules) so an edited order can never end up in a state the create path itself wouldn't have
-- allowed, and reuses the exact same per-line insert shape (CategoryCode/ItemCode/ItemName/
-- Quantity/Price/Notes/VariationId - see supabase_gma_conversation_order_line_variant_selection.sql)
-- so a re-saved order's Pancake push behaves identically to a freshly created one. Lines are fully
-- replaced (delete-then-reinsert) rather than diffed - simplest correct way to support add/remove/
-- reorder/qty-and-price-change all through one JSONB array, same "whole array in, whole array
-- applied" shape the create RPC already uses.
--
-- Pancake re-sync is INTENTIONALLY NOT automatic once an order has already synced successfully.
-- admin_retry_automated_order_pancake_push's own header comment already flags exactly why: Pancake's
-- order-creation endpoint has no idempotency key to upsert against, so calling
-- _push_automated_order_to_pancake again after a 'Synced' order would create a SECOND, separate
-- order in Pancake rather than updating the first one - and there is no proven "update line items on
-- an already-created Pancake order" call anywhere in this codebase (only status/bank_payments
-- PATCHes exist - see admin_update_online_order_status). So:
--   - Order hasn't successfully synced yet (Pending/Failed/Stale) - editing is fully safe, and this
--     re-attempts the push with the new lines, same as a Retry click.
--   - Order already synced (a real Pancake order exists) - the LOCAL record is still updated (so
--     staff have a correct record and invoices/receipts reflect it), but PancakeSyncStatus flips to
--     'Stale' with a clear PancakeSyncError explaining the live Pancake order was NOT touched and
--     needs a manual fix there too - never a silent duplicate order.
-- Editing is blocked outright once the order is Completed or Cancelled - matches the conservative,
-- narrow-status-transition philosophy admin_update_automated_order_status/admin_update_online_order_
-- status already use elsewhere in this codebase.

drop function if exists public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb);

create or replace function public.admin_update_automated_order(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_lines jsonb
)
returns table(order_no text, estimated_total numeric, pancake_sync_status text, pancake_sync_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_current_status text;
  v_current_sync_status text;
  v_fulfillment text := coalesce(nullif(trim(p_fulfillment_type), ''), 'Pickup');
  v_location text := coalesce(nullif(trim(p_location), ''), 'Amaya');
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "Status", "PancakeSyncStatus" into v_current_status, v_current_sync_status
  from public."AutomatedOrders"
  where "OrderNo" = p_order_no;

  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  if v_current_status in ('Completed', 'Cancelled') then
    raise exception 'This order is % and can no longer be edited.', v_current_status;
  end if;

  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Customer phone number is required.';
  end if;
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

  update public."AutomatedOrders"
  set "CustomerName" = trim(p_customer_name),
      "CustomerPhone" = trim(p_customer_phone),
      "CustomerEmail" = nullif(trim(coalesce(p_customer_email, '')), ''),
      "FulfillmentType" = v_fulfillment,
      "DeliveryAddress" = case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
      "Notes" = nullif(trim(coalesce(p_notes, '')), ''),
      "Location" = v_location,
      "UpdatedBy" = p_admin_username,
      "UpdatedAtUtc" = now()
  where "OrderNo" = p_order_no;

  delete from public."AutomatedOrderLines" where "OrderNo" = p_order_no;

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
      (p_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price,
       nullif(trim(coalesce(v_line->>'note', '')), ''), nullif(trim(coalesce(v_line->>'variation_id', '')), ''));

    v_total := v_total + (v_qty * v_price);
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = p_order_no;

  if v_current_sync_status = 'Synced' then
    update public."AutomatedOrders"
    set "PancakeSyncStatus" = 'Stale',
        "PancakeSyncError" = 'Order was edited in the portal after already syncing to Pancake - the existing Pancake order was NOT updated automatically (no safe way to edit an already-created Pancake order). Please update it manually in Pancake, or contact the customer to confirm the change.'
    where "OrderNo" = p_order_no;
  else
    perform public._push_automated_order_to_pancake(p_order_no);
  end if;

  return query
    select o."OrderNo"::text, o."EstimatedTotal", o."PancakeSyncStatus"::text, o."PancakeSyncError"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = p_order_no;
end;
$$;

grant execute on function public.admin_update_automated_order(text, text, text, text, text, text, text, text, text, text, jsonb) to anon;
