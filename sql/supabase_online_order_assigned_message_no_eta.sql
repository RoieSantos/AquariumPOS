-- "In production" message without the estimated completion date - per "dont add the estimated completion
-- in the message to customer remove that.. it will only show on the maker's list".
--
-- Same as _send_online_order_assigned_message in supabase_online_order_assigned_message.sql, minus the
-- "📅 Estimated completion: ..." line. The date is still set on Assign (admin_sync_online_order_assigned_
-- status) and shown to makers as "Due" on My Assignments and the order. Run AFTER
-- supabase_online_order_assigned_message.sql. Replaces one function - no table locks.

create or replace function public._send_online_order_assigned_message(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."OnlineOrders"%rowtype;
  v_items_text text;
  v_message text;
  v_response extensions.http_response;
begin
  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found or v_order."Page_ID" is null or v_order."Conversation_ID" is null
     or trim(v_order."Page_ID") = '' or trim(v_order."Conversation_ID") = '' then
    raise exception 'Order is missing Page_ID/Conversation_ID - cannot message this customer.';
  end if;

  select string_agg(
    '✅ ' || trim(to_char(coalesce(l."Quantity", 1), 'FM999999990.##')) || ' x ' || coalesce(nullif(trim(l."Description"), ''), l."ItemCode")
      || case when nullif(trim(coalesce(l."Note", '')), '') is null then '' else ' 🧾 Note : ' || l."Note" end,
    chr(10) order by l."LineID"
  ) into v_items_text
  from public."OnlineOrderLines" l
  where l."OrderID" = p_order_id;

  -- ---- Message text: edit here ----
  v_message :=
    '🎉 Hi ' || coalesce(nullif(trim(v_order."CustomerName"), ''), 'there') || '! Good news - your order ' || p_order_id
    || ' is now in production. Our team has been assigned and has started building your items.' || chr(10) || chr(10)
    || '🧾 Here''s what we''re making:' || chr(10) || chr(10)
    || coalesce(v_items_text, '') || chr(10) || chr(10)
    || 'We''ll message you again once your order is ready. For any urgent matters, call +63 997 189 1662 or drop us a message here.'
    || chr(10) || chr(10)
    || 'Happy fish keeping 🐟 😊';
  -- ---------------------------------

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  select * into v_response from extensions.http((
    'POST',
    'https://pages.fm/api/public_api/v1/pages/' || v_order."Page_ID" || '/conversations/' || v_order."Conversation_ID"
      || '/messages?page_access_token=' || public._pancake_public_api_key(),
    array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
    'application/json',
    -- json_build_object (not jsonb) keeps this key order - see _send_online_order_status_message.
    json_build_object('action', 'reply_inbox', 'message', v_message)::text
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake messaging API returned HTTP %.', v_response.status;
  end if;
end;
$$;

revoke execute on function public._send_online_order_assigned_message(text) from public, anon, authenticated;
