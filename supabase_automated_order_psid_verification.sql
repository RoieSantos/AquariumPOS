-- Fix 1 (the one this file is named for): "what if a customer copies their Messenger-personalized
-- Order Now link (?psid=...) and sends it to someone else?" - traced through the code and it's a
-- real problem, not just a cosmetic one. js/orderNow.js's captureMessengerPsid() stores whatever
-- psid is in the URL and submit_automated_order stamps it on the order unconditionally; that Psid
-- then drives BOTH _push_automated_order_to_pancake (attaches the order to that psid's existing
-- Pancake customer_id/conversation_id) AND _send_order_confirmation_message (posts a Messenger
-- message listing the order's items/price into that psid's conversation). So: forward the link to
-- someone else, and their order gets attached to YOUR Pancake profile, and YOU get a Messenger
-- message revealing their order details - not just "an extra order under a customer", an actual
-- misattribution + information leak to an unrelated person.
--
-- Since the link itself is Pancake's own personalized-Messenger-button URL (not something this
-- app issues as a single-use token), we can't stop it being copied. What we CAN do is stop trusting
-- it blindly: only attach/message a psid when the phone number actually being submitted matches
-- the phone Pancake has on file for that psid (same normalized-digits form the phone validation
-- below already uses). A stranger using a copied link will almost certainly submit their OWN phone
-- number (it's a required, validated field) - that mismatch is what nulls the psid back out before
-- it's ever stored, so their order just goes through as a normal, unattached submission (identical
-- to anyone who reaches Order Now without a Messenger link at all).
--
-- Fallback for a psid with NO phone on file yet in OnlineCustomers (a brand new Messenger contact,
-- or one whose Pancake record just hasn't synced a number) - requiring a match against nothing
-- would drop the psid for every genuine first-time order too. Instead, that case is checked
-- against our OWN AutomatedOrders history for the same psid: trusted if this is the first order
-- ever submitted under it (nothing to conflict with yet), rejected if a prior order under the same
-- psid used a different phone. This leaves one narrow, one-shot residual case - if a copied link
-- reaches someone else before the real owner ever places a single order through it, that first
-- submission is unverifiable and gets trusted, same as it would for a genuinely new customer.
-- Every use after that first one is then checked against the phone that first order recorded.
--
-- Fix 2 (bundled in because it touches this exact function): supabase_automated_order_async_pancake_sync.sql
-- (2026-08-21/23) redefined submit_automated_order to remove the synchronous Pancake push, but in
-- doing so it also dropped the server-side price lookup that supabase_submit_automated_order_price_validation.sql
-- (2026-08-20) had added - the live function currently trusts the client-submitted price again for
-- every line, including real catalog items. Restored here: a line with a real item_code has its
-- price looked up from Items.RetailPrice/Price server-side, never taken from the client; only a
-- Customize-flow line (no item_code at all) still falls back to the client-submitted price, same
-- documented residual gap as before.
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

  -- Anti link-sharing check - see file header. Only keep the psid when it's verifiably the same
  -- person submitting.
  if v_psid is not null then
    if exists (
      select 1 from public."OnlineCustomers" c
      where (c."FbID" = v_psid or c."FbID" = '195716644410829_' || v_psid)
        and nullif(trim(coalesce(c."PrimaryPhoneNumber", '')), '') is not null
    ) then
      -- Pancake has a phone on file for this psid (synced by FbID - same lookup shape
      -- public_lookup_customer_by_psid and _push_automated_order_to_pancake already use) - require
      -- it to match what's actually being submitted right now.
      if not exists (
        select 1 from public."OnlineCustomers" c
        where (c."FbID" = v_psid or c."FbID" = '195716644410829_' || v_psid)
          and regexp_replace(c."PrimaryPhoneNumber", '[^0-9]', '', 'g') = regexp_replace(p_customer_phone, '[^0-9]', '', 'g')
      ) then
        v_psid := null;
      end if;
    else
      -- No phone on file yet for this psid at all - e.g. a brand new Messenger contact who's never
      -- given Pancake a number before. Blindly requiring a match here would drop the psid for
      -- EVERY genuine first-time order too, not just forwarded links. Fall back to our own order
      -- history instead: if this exact psid already placed an AutomatedOrders request with a
      -- DIFFERENT phone, someone else is now reusing that link - drop it. If this is the very
      -- first order ever submitted under this psid, there's nothing to compare against yet, so
      -- it's trusted (same posture as any brand new customer) - any later re-use of the SAME link
      -- is then checked against the phone recorded on THIS order.
      if exists (
        select 1 from public."AutomatedOrders" ao
        where ao."Psid" = v_psid
          and regexp_replace(coalesce(ao."CustomerPhone", ''), '[^0-9]', '', 'g') <> regexp_replace(p_customer_phone, '[^0-9]', '', 'g')
      ) then
        v_psid := null;
      end if;
    end if;
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

    -- Price-validation fix (see file header): a real catalog item_code always gets its price
    -- looked up server-side, never taken from the client. Only a line with no item_code at all (a
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

  -- Pancake push + confirmation message deliberately NOT called here - see
  -- supabase_automated_order_async_pancake_sync.sql's file header. The row stays at its default
  -- PancakeSyncStatus = 'Pending'; js/orderNow.js fires public_sync_automated_order_to_pancake()
  -- right after this returns (without awaiting it), and cron_process_pending_automated_orders() is
  -- the once-a-minute safety net for whatever that browser-driven call misses.

  return query
    select o."OrderNo"::text, o."PancakeOrderId"::text, o."PancakeSyncStatus"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = v_order_no;
end;
$$;

grant execute on function public.submit_automated_order(text, text, text, text, text, text, text, text, jsonb) to anon;
