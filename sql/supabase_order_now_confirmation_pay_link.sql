-- Order Now "Order Received" Messenger message: adds the Xendit online pay link
-- (https://www.rspetstop.com/pay.html?order=AO-#####) when online payment is switched on for Order Now
-- (XenditSettings.Enabled AND ShowOnOrderNow - the same rule as the "Pay down payment online" button
-- on the Order Now Thank-you screen). When it's off, the message is exactly the same as before.
-- Also asks the customer to reply with a screenshot of the Order ID + proof of payment.
--
-- Replaces _build_order_confirmation_message from supabase_automated_order_confirmation_payment_info.sql
-- (don't re-run that older file after this one - it would remove the pay link again).
-- Run AFTER supabase_xendit_payments.sql. Safe to re-run.

create or replace function public._build_order_confirmation_message(p_order_no text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."AutomatedOrders"%rowtype;
  v_lines_text text;
  v_pay_online boolean := false;
begin
  select * into v_order from public."AutomatedOrders" where "OrderNo" = p_order_no;
  if not found then
    raise exception 'AutomatedOrders row % not found.', p_order_no;
  end if;

  select coalesce(s."Enabled" and s."ShowOnOrderNow", false) into v_pay_online
  from public."XenditSettings" s where s."Id" = 1;
  v_pay_online := coalesce(v_pay_online, false);

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
    case when v_pay_online then
      '💳 Pay Online (fastest - confirmed automatically)' || E'\n' ||
      'GCash (via QR Ph), Maya, GrabPay, BPI / RCBC, Cebuana / LBC, or card:' || E'\n' ||
      'https://www.rspetstop.com/pay.html?order=' || p_order_no || E'\n\n' ||
      'Or pay manually:' || E'\n\n'
    else '' end ||
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
    '💡 For manual payments, kindly send proof of payment + your full name + your Order No (' || p_order_no || ') here after the transaction.' || E'\n\n' ||
    '🚫 Cancellation & Refunds' || E'\n' ||
    'Down payments are non-refundable once processing begins.' || E'\n\n' ||
    'We''ll reach out shortly to confirm details and payment.' || E'\n' ||
    'Thank you for choosing RS Pet Stop! 🐟';
end;
$$;

-- Check: preview the message for the latest Order Now order (read-only).
select o."OrderNo", public._build_order_confirmation_message(o."OrderNo") as message
from public."AutomatedOrders" o
order by o."CreatedAtUtc" desc nulls last
limit 1;
