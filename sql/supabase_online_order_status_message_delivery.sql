-- Ready to Ship customer message: a DELIVERY version - per "sometimes the order is scheduled for delivery and
-- the customer is a bit confused that it's stating ready for pickup".
--
-- Before: every To Ship message said "ready for pickup at RSPetStop" + "Please settle remaining balance to
-- continue on the delivery" - pickup and delivery mixed in one message.
-- Now the order is treated as a DELIVERY when (A) it's on the Delivery schedule (DeliveryStops) or (B) the
-- customer chose delivery (OnlineOrders.ForDelivery / AutomatedOrders.FulfillmentType = 'Delivery').
-- A delivery fee or saved address alone does NOT count (some pickup orders have one too).
--   - Delivery, scheduled:   "...is ready and scheduled for delivery on Thu, Nov 13. 🚚" + address
--   - Delivery, no date yet: "...is ready for delivery! We'll message you the delivery schedule shortly."
--   - Pickup:                same short "ready for pickup at RSPetStop Amaya" message as before
--   - Pending Transfer:      unchanged
-- Balance line follows the type ("before delivery so we can dispatch it" / "before pickup").
-- Delivery messages have no store-hours / GMA / Lalamove lines (they don't apply).
--
-- One shared function, so the To Ship status change (Pancake + GMA routes) and the TO-SHIP composer button
-- all send the same words. Tip: schedule the delivery first, then click Ready to Ship, so the date shows.
--
-- Run AFTER supabase_online_order_status_message_gma.sql and supabase_online_order_assigned_message_short.sql
-- (uses its _online_order_message_item_name). Replaces supabase_online_order_status_message_short.sql's
-- version - don't re-run that one after this. Functions only - no table locks. Safe to re-run. Ends with ONE
-- result (a preview - nothing is sent).

create or replace function public._online_order_status_message_text(p_order_id text, p_new_status text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."OnlineOrders"%rowtype;
  v_auto_no text;
  v_auto_delivery boolean := false;
  v_auto_address text;
  v_stop_date date;
  v_stop_address text;
  v_has_stop boolean := false;
  v_is_delivery boolean;
  v_address text;
  v_sets_text text;
  v_items_text text;
  v_list text := '';
  v_balance_text text := '';
  v_headline text;
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;

  -- (B) the bot / Order Now order this came from
  select ao."OrderNo", ao."FulfillmentType" = 'Delivery', nullif(trim(ao."DeliveryAddress"), '')
    into v_auto_no, v_auto_delivery, v_auto_address
  from public."AutomatedOrders" ao
  where ao."PancakeReceiptNo" = p_order_id
  limit 1;

  -- (A) on the Delivery schedule: the next upcoming date (else the latest one)
  select s."DeliveryDate", nullif(trim(s."ManualAddress"), '')
    into v_stop_date, v_stop_address
  from public."DeliveryStops" s
  where s."OrderID" = p_order_id or (v_auto_no is not null and s."AutomatedOrderNo" = v_auto_no)
  order by (s."DeliveryDate" < v_today), case when s."DeliveryDate" >= v_today then s."DeliveryDate" end,
           s."DeliveryDate" desc
  limit 1;
  v_has_stop := found;
  if v_stop_date < v_today then
    v_stop_date := null;   -- only a past date on file - don't quote it
  end if;

  v_is_delivery := v_has_stop or coalesce(v_order."ForDelivery", false) or coalesce(v_auto_delivery, false);
  v_address := coalesce(v_stop_address, nullif(trim(v_order."ShippingAddress"), ''), v_auto_address);

  with lines as (
    select l."LineID",
           coalesce(l."Quantity", 1) as qty,
           public._online_order_message_item_name(l."Description", coalesce(nullif(trim(l."ItemCode"), ''), l."product_display_id")) as name,
           upper(coalesce(public._online_order_line_category(l."VariationId",
             coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), ''))), '')) = 'SET'
             and l."LineID" not like '%~SETMAT~%' as is_set,
           -- the note minus the automatic "SET Material for ..." / "SET Materials: ..." text
           nullif(trim(regexp_replace(coalesce(l."Note", ''), '\s*SET Materials?(:| for ).*$', '', 'i')), '') as note
    from public."OnlineOrderLines" l
    where l."OrderID" = p_order_id
  )
  select
    string_agg('📦 Your set: ' || name || coalesce(chr(10) || '📝 ' || note, ''), chr(10) order by "LineID") filter (where is_set),
    string_agg('• ' || trim(to_char(qty, 'FM999999990.##')) || ' x ' || name || coalesce(' (📝 ' || note || ')', ''), chr(10) order by "LineID") filter (where not is_set)
  into v_sets_text, v_items_text
  from lines;

  if v_sets_text is not null then
    v_list := v_sets_text || chr(10) || chr(10);
  end if;
  if v_items_text is not null then
    v_list := v_list
      || case when v_sets_text is not null then '🧾 What''s included:' else '🧾 Your items:' end
      || chr(10) || v_items_text || chr(10) || chr(10);
  end if;

  -- ---- Message text: edit here ----
  if coalesce(v_order."Balance", 0) > 0 then
    v_balance_text := '💰 Balance to settle: ₱' || to_char(v_order."Balance", 'FM999,999,990.00')
      || case when lower(trim(p_new_status)) = 'pending transfer' then ' (please settle before pickup or delivery)'
              when v_is_delivery then ' (please settle before delivery so we can dispatch it)'
              else ' (please settle before pickup)' end
      || chr(10) || chr(10);
  end if;

  if lower(trim(p_new_status)) = 'pending transfer' then
    v_headline := 'Your order ' || p_order_id || ' is finished! 🎉 We''ll bring it to RSPetStop '
      || coalesce(nullif(trim(v_order."LocationID"), ''), 'your branch')
      || ' on our next delivery schedule and message you once it''s ready for pickup there.';
  elsif v_is_delivery and v_stop_date is not null then
    v_headline := 'Your order ' || p_order_id || ' is ready and scheduled for delivery on '
      || to_char(v_stop_date, 'FMDy, FMMon FMDD') || '. 🚚';
  elsif v_is_delivery then
    v_headline := 'Your order ' || p_order_id || ' is ready for delivery! 🚚 We''ll message you the delivery schedule shortly.';
  else
    v_headline := 'Your order ' || p_order_id || ' is ready for pickup at RSPetStop Amaya! 🎉';
  end if;

  if v_is_delivery and lower(trim(p_new_status)) <> 'pending transfer' then
    return
      '🎉 Hi ' || coalesce(nullif(trim(v_order."CustomerName"), ''), 'there') || '! ' || v_headline
      || chr(10) || chr(10)
      || coalesce('📍 Delivery address: ' || v_address || chr(10)
                  || '(If this isn''t right, just reply here so we can update it.)' || chr(10) || chr(10), '')
      || v_balance_text
      || v_list
      || '📞 +63 997 189 1662' || chr(10) || chr(10)
      || 'Thank you for choosing RSPetStop! 🐟❤️';
  end if;

  return
    '🎉 Hi ' || coalesce(nullif(trim(v_order."CustomerName"), ''), 'there') || '! ' || v_headline
    || chr(10) || chr(10)
    || v_balance_text
    || v_list
    || '📍 Amaya: Amaya Dos, Antero Soriano Hwy, Tanza, Cavite (Pin: RSPetStop Amaya)' || chr(10)
    || '🕒 Open daily, 8:00 AM - 8:00 PM' || chr(10)
    || '📞 +63 997 189 1662' || chr(10) || chr(10)
    || case when lower(trim(p_new_status)) = 'pending transfer' then ''
         else '🏬 Prefer our GMA branch? We can bring it on our next delivery schedule - just let us know.' || chr(10) end
    || '🚚 Need delivery? We can book a Lalamove for you - send your full name, contact number, complete address and pin location.'
    || chr(10) || chr(10)
    || 'Thank you for choosing RSPetStop! 🐟❤️';
  -- ---------------------------------
end;
$$;

revoke execute on function public._online_order_status_message_text(text, text) from public, anon, authenticated;

-- "TO-SHIP" composer button: same text as the status-change message.
create or replace function public.admin_render_online_order_to_ship_message(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (select 1 from public."OnlineOrders" where "OrderID" = p_order_id) then
    raise exception 'Order % not found.', p_order_id;
  end if;

  return public._online_order_status_message_text(p_order_id, 'To Ship');
end;
$$;

grant execute on function public.admin_render_online_order_to_ship_message(text, text, text) to anon;

-- Preview (doesn't send anything) - one result. Change AO-00216 to check another order.
select public._online_order_status_message_text('AO-00216', 'To Ship') as preview;
