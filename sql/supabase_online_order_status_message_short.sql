-- "Ready for pickup" / "Pending transfer" customer message: short and clear - per "notice this message is so
-- long. can we make it better / shorter and informative".
--
-- Before: every line with its full Note - a SET order repeated the set name 6+ times ("SET Material for
-- <set> (AS-012 - <set> - AS-012)" on every part, plus a "SET Materials: ..." list on the SET line), item
-- codes in every name, and a long footer (two "thank you"s, the same phone line, etc.).
-- Now (same style as supabase_online_order_assigned_message_short.sql's "in production" message):
--   🎉 Hi <name>! Your order AO-00048 is ready for pickup at RSPetStop Amaya.
--   💰 Balance to settle: ₱100.00 (please settle before pickup or delivery)
--   📦 Your set: 50GALLONS-AQUARIUM-6MM (OVERHEAD COMPETE SETUP SET)
--   📝 Black Sealant / Black Paint Stand / Black Tile Sticker
--   🧾 What's included:
--   • 1 x STANDARD-50G ( 36×18×18in, 6MM GLASS)
--   ...
--   short location / hours / phone / GMA / Lalamove block
-- Names are shortened by _online_order_message_item_name (code prefix + "(AS-012 - ... - AS-012)" repeat
-- dropped). Notes are kept only when the customer/staff wrote them - the automatic "SET Material for ..." and
-- "SET Materials: ..." text is removed.
--
-- One shared text function: the To Ship status change (Pancake + GMA routes) and the "TO-SHIP" composer button
-- (admin_render_online_order_to_ship_message) now both use _online_order_status_message_text, so they can't drift.
-- The desktop POS (GlobalSettings.cs) still has its own copy of the old template.
--
-- Run AFTER supabase_online_order_status_message_gma.sql, supabase_online_order_send_message.sql and
-- supabase_online_order_assigned_message_short.sql (uses its _online_order_message_item_name). If any of the
-- first two is re-run, run this one again after it. Functions only - no table locks. Safe to re-run.

create or replace function public._online_order_status_message_text(p_order_id text, p_new_status text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."OnlineOrders"%rowtype;
  v_sets_text text;
  v_items_text text;
  v_list text := '';
  v_balance_text text := '';
  v_headline text;
begin
  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;

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

  if coalesce(v_order."Balance", 0) > 0 then
    v_balance_text := '💰 Balance to settle: ₱' || to_char(v_order."Balance", 'FM999,999,990.00')
      || ' (please settle before pickup or delivery)' || chr(10) || chr(10);
  end if;

  -- ---- Message text: edit here ----
  if lower(trim(p_new_status)) = 'pending transfer' then
    v_headline := 'Your order ' || p_order_id || ' is finished! 🎉 We''ll bring it to RSPetStop '
      || coalesce(nullif(trim(v_order."LocationID"), ''), 'your branch')
      || ' on our next delivery schedule and message you once it''s ready for pickup there.';
  else
    v_headline := 'Your order ' || p_order_id || ' is ready for pickup at RSPetStop Amaya! 🎉';
  end if;

  return
    'Hi ' || coalesce(nullif(trim(v_order."CustomerName"), ''), 'there') || '! ' || v_headline
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

-- "TO-SHIP" composer button: same text as the status-change message (was its own copy of the old template).
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

-- Preview (doesn't send anything) - one result:
select public._online_order_status_message_text('AO-00048', 'To Ship') as preview;
