-- Follow-up to supabase_automated_orders_tables.sql's _build_order_confirmation_message - adds a
-- payment-methods section to the end of the order confirmation message, so customers can pay
-- ahead of time instead of waiting for staff to follow up. Shared by both the real send path
-- (_send_order_confirmation_message) and the diagnostic test-send version, so both keep sending
-- the exact same text.
drop function if exists public._build_order_confirmation_message(text);

create or replace function public._build_order_confirmation_message(p_order_no text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_lines_text text;
begin
  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;

  -- One bullet line per item, e.g. "🔹 Custom Aquarium - 24 x 12 x 12 Inches... x1 — ₱936.00" -
  -- ₱ and en-PH-style thousands separators match how the rest of the app formats money
  -- (js/orderNow.js's formatMoney), so this reads the same as the price shown in the wizard.
  select string_agg('🔹 ' || l."ItemName" || ' x' || l."Quantity" || ' — ₱' || to_char(l."Price" * l."Quantity", 'FM999,999,990.00'), E'\n' order by l."EntryNo")
  into v_lines_text
  from public."AutomatedOrderLines" l
  where l."OrderNo" = p_order_no;

  return
    '🐠 Order Received - RS Pet Stop!' || E'\n\n' ||
    'Hi ' || v_order."CustomerName" || ', thank you for your order! Here''s a summary:' || E'\n\n' ||
    '📋 Automated Order No: ' || p_order_no
      || coalesce(E'\n' || '     Online Order ID: #' || v_order."PancakeOrderId", '') || E'\n\n' ||
    '🛒 Items' || E'\n' || coalesce(v_lines_text, '(no items)') || E'\n\n' ||
    '💰 Estimated Total: ₱' || to_char(v_order."EstimatedTotal", 'FM999,999,990.00') || E'\n\n' ||
    case
      when v_order."FulfillmentType" = 'Delivery' then '🚚 Delivery to: ' || coalesce(v_order."DeliveryAddress", '(address on file)')
      else '🏬 Pickup at: ' || coalesce(v_order."Location", 'our branch')
    end
      || coalesce(E'\n\n' || '📝 Notes: ' || nullif(trim(v_order."Notes"), ''), '') || E'\n\n' ||
    'To speed things up on your order, you can now pay ahead using our payment methods below:' || E'\n\n' ||
    '💰 Payment Methods Available' || E'\n' ||
    '📱 GCash' || E'\n' ||
    '• Name: Roie del Bert P. Santos' || E'\n' ||
    '• Number: 0995-753-4317' || E'\n\n' ||
    '🏦 Metrobank' || E'\n' ||
    '• Acct No.: 3773853016749' || E'\n' ||
    '• Name: Roie del Bert P. Santos' || E'\n\n' ||
    '🏦 BDO' || E'\n' ||
    '• Acct No.: 012490055360' || E'\n' ||
    '• Name: Roie del Bert P. Santos' || E'\n\n' ||
    '💡 Kindly send proof of payment + your full name after transaction.' || E'\n\n' ||
    '🚫 Cancellation & Refunds' || E'\n' ||
    'Down payments are non-refundable once processing begins.' || E'\n\n' ||
    'We''ll reach out shortly to confirm details and payment.' || E'\n' ||
    'Thank you for choosing RS Pet Stop! 🐟';
end;
$$;

-- No grant to anon - internal helper only, called from _send_order_confirmation_message and
-- debug_send_order_confirmation_message.
