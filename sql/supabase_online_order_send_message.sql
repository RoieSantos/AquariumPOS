-- Lets staff send a freeform Messenger message to a customer directly from the Online Orders page
-- (docs/online-orders.html), per direct request to bring GMA Conversations' "Send to customer"
-- capability to this page too - not every order that ends up here was created from a GMA
-- conversation, so a single button needs to route to the RIGHT platform depending on where the
-- order actually came from:
--
--   - A GMA-originated order (admin_create_gma_conversation_order) was pushed to Pancake with NO
--     customer_id/conversation_id (Psid is always null for these - see supabase_gma_conversation_
--     orders.sql's header comment), so Pancake has NO conversation to message through. These are
--     only reachable via the GMA Facebook Page's own Graph API - the SAME mechanism GMA
--     Conversations' own "Send to customer" button already uses (chatbot-staff-reply Edge
--     Function), just triggered from this page instead. admin_get_online_order_messaging_route
--     below tells the client which case it's in so js/onlineOrders.js can call that Edge Function
--     directly with the right psid - no SQL involved in that send, same as GMA Conversations.
--   - Every other order came in through the actual Pancake-connected Page and DOES have a Pancake
--     conversation (Page_ID/Conversation_ID columns, already populated by the regular Pancake
--     sync) - these go through admin_send_online_order_message below, which is the exact same
--     Pancake public-conversations-API call _send_online_order_status_message already makes
--     (supabase_online_order_portal_status_update.sql), just with a freeform message instead of
--     one of its two hardcoded status templates.
--
-- An order is always exactly one of these two cases, never both or neither (as long as it has a
-- conversation at all) - GmaPsid and a real Pancake conversation are mutually exclusive by how the
-- order was created, so there's no ambiguity about which platform to use once the route is known.

-- ---------------------------------------------------------------------------
-- admin_get_online_order_messaging_route: tells the client which of the two cases above applies to
-- this order, plus the specific psid needed for the GMA case. is_staff_authorized (not admin) -
-- same trust level as the rest of this page's RPCs (admin_update_online_order_status etc).
-- ---------------------------------------------------------------------------

drop function if exists public.admin_get_online_order_messaging_route(text, text, text);

create or replace function public.admin_get_online_order_messaging_route(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(
  customer_name text,
  is_gma_order boolean,
  gma_psid text,
  has_pancake_conversation boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_gma_psid text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not exists (select 1 from public."OnlineOrders" where "OrderID" = p_order_id) then
    raise exception 'Order % not found.', p_order_id;
  end if;

  -- Same join admin_list_online_orders already uses for the "GMA Page" badge (is_gma_order) - see
  -- supabase_orders_sync_tables.sql - just also pulling GmaPsid here, which that RPC never needed
  -- to expose before now.
  select ao."GmaPsid" into v_gma_psid
  from public."AutomatedOrders" ao
  where ao."PancakeReceiptNo" = p_order_id
    and ao."GmaPsid" is not null
  limit 1;

  return query
    select
      o."CustomerName"::text,
      (v_gma_psid is not null),
      v_gma_psid,
      (o."Page_ID" is not null and trim(o."Page_ID") <> '' and o."Conversation_ID" is not null and trim(o."Conversation_ID") <> '')
    from public."OnlineOrders" o
    where o."OrderID" = p_order_id;
end;
$$;

grant execute on function public.admin_get_online_order_messaging_route(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_send_online_order_message: the non-GMA (regular Pancake-page) send path. Copied verbatim
-- from _send_online_order_status_message's own Pancake-call block (supabase_online_order_portal_
-- status_update.sql) - same URL shape, same _pancake_public_api_key(), same reply_inbox payload -
-- just with p_message taking the place of that function's two hardcoded templates.
-- ---------------------------------------------------------------------------

drop function if exists public.admin_send_online_order_message(text, text, text, text);

create or replace function public.admin_send_online_order_message(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_message text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."OnlineOrders"%rowtype;
  v_url text;
  v_response extensions.http_response;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_message is null or trim(p_message) = '' then
    raise exception 'Message cannot be empty.';
  end if;

  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    raise exception 'Order % not found.', p_order_id;
  end if;
  if v_order."Page_ID" is null or v_order."Conversation_ID" is null
     or trim(v_order."Page_ID") = '' or trim(v_order."Conversation_ID") = '' then
    raise exception 'This order has no linked Pancake conversation to message - it may be a GMA order (use the GMA route instead) or have no Messenger conversation attached at all.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  v_url := 'https://pages.fm/api/public_api/v1/pages/' || v_order."Page_ID" || '/conversations/' || v_order."Conversation_ID"
    || '/messages?page_access_token=' || public._pancake_public_api_key();

  select * into v_response from extensions.http((
    'POST',
    v_url,
    array[
      extensions.http_header('Accept', 'application/json'),
      extensions.http_header('Expect', '')
    ],
    'application/json',
    -- json_build_object (not jsonb_build_object) - same reason _send_online_order_status_message's
    -- own comment gives: key order matters to Pancake here.
    json_build_object('action', 'reply_inbox', 'message', trim(p_message))::text
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake messaging API returned HTTP %: %', v_response.status, left(v_response.content, 300);
  end if;
end;
$$;

grant execute on function public.admin_send_online_order_message(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_render_online_order_to_ship_message: renders the desktop app's own "your order is ready"
-- template (GlobalSettings.PickupReadyMessage / _send_online_order_status_message's non-pending-
-- transfer branch, supabase_online_order_portal_status_update.sql) filled in for one order, WITHOUT
-- sending anything. Per direct request, the "Send Message" button above is now labeled "TO-SHIP"
-- and prefills its composer with this exact text, so staff get the same automated To-Ship message
-- the desktop app/admin_update_online_order_status sends for a regular Pancake-conversation order -
-- but this route also reaches GMA orders, which that status-change path can't message (no Pancake
-- conversation - see this file's header comment) and which admin_update_online_order_status's own
-- 'Printed' gate may not even let staff reach yet.
--
-- Template/placeholder-filling copied verbatim from _send_online_order_status_message's else branch
-- rather than shared - that function isn't reachable from here without changing an already-
-- committed file, and this codebase already duplicates in the same situation (see js/onlineOrders.js's
-- resolveIsProductionWarehouse comment).
-- ---------------------------------------------------------------------------

drop function if exists public.admin_render_online_order_to_ship_message(text, text, text);

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
declare
  v_order public."OnlineOrders"%rowtype;
  v_template text;
  v_items_text text;
  v_payment_text text := '';
  v_message text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    raise exception 'Order % not found.', p_order_id;
  end if;

  v_template := $msg$🎉 Hi {Customer Name}! Your order {Order ID} is now ready for pickup at RSPetStop.
{Payment}

🧾 Heres what youll be receiving:

 {Items}


Swing by anytime during our store hours—your fish joy is just one finstep away! 🐠🦈
📍 Location: Amaya Dos Antero Soriano Highway Tanza Cavite or just Pin : RSPetStop Amaya
🕒 Hours: 8:00 am to 8:00 pm monday to sunday
For GMA Location, You can pickup your order on the next Delivery schedule. You can coordinate with us with this. Happy fish keeping.
You may call +63 997 189 1662 (GMA Branch) for any questions or assistance. We look forward to seeing you soon! 🐟❤️
We can also help you book a lalamove delivery partner
📦 Kindly send the following details

• Full Name:
• Contact Number:
• Complete Address:
• Pin Location (Google Maps link or screenshot):
💬 Once received, well confirm your order and send the final details right away. Thank you
Thank you for choosing RSPetStop—We appreciate you always! and see you soon ❤️$msg$;

  select string_agg(
    case when nullif(trim(coalesce(l."Note", '')), '') is null
      then '✅ ' || trim(to_char(coalesce(l."Quantity", 1), 'FM999999990.##')) || ' x ' || coalesce(nullif(trim(l."Description"), ''), l."ItemCode")
      else '✅ ' || trim(to_char(coalesce(l."Quantity", 1), 'FM999999990.##')) || ' x ' || coalesce(nullif(trim(l."Description"), ''), l."ItemCode") || ' 🧾 Note : ' || l."Note"
    end,
    chr(10) order by l."LineID"
  ) into v_items_text
  from public."OnlineOrderLines" l
  where l."OrderID" = p_order_id;

  if coalesce(v_order."Balance", 0) > 0 then
    v_payment_text := 'Please settle remaining balance to continue on the delivery.' || chr(10) || chr(10) ||
      'Balance : ' || to_char(v_order."Balance", 'FM999,999,990.00');
  end if;

  v_message := v_template;
  v_message := replace(v_message, '{Customer Name}', coalesce(v_order."CustomerName", ''));
  v_message := replace(v_message, '{Order ID}', p_order_id);
  v_message := replace(v_message, '{location}', coalesce(v_order."LocationID", ''));
  v_message := replace(v_message, '{Payment}', v_payment_text);
  v_message := replace(v_message, '{Items}', coalesce(v_items_text, ''));

  return v_message;
end;
$$;

grant execute on function public.admin_render_online_order_to_ship_message(text, text, text) to anon;
