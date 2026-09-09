-- Follow-up to supabase_automated_order_rate_limit.sql - per direct discussion: worried that a
-- customer mistyping their phone number could cause a "missing order."
--
-- Clarification worth keeping in the record: a phone mismatch never dropped the order itself -
-- the insert into AutomatedOrders always ran regardless. All the old phone-match fallback (the
-- "no token" branch below) did was silently null out Psid when the typed phone didn't match
-- OnlineCustomers.PrimaryPhoneNumber, or didn't match prior AutomatedOrders history. That's just
-- loss of Messenger attribution (no auto-confirmation message in the customer's FB chat, no
-- conversation link for staff), not a lost order.
--
-- Still, it's a fragile, invisible-failure check for very little benefit, since it only ever ran
-- in the rare no-token case (JS disabled, or a stale cached page from before the token system
-- shipped - the normal flow always has a token by the time submit runs). Fix: drop the phone-match
-- comparison entirely. In the no-token case, just don't attach Psid at all - same safe default as
-- an unrecognized/expired token, with zero chance of a typo doing anything at all, visible or not.
drop function if exists public.submit_automated_order(text, text, text, text, text, text, text, text, text, jsonb);

create or replace function public.submit_automated_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text,
  p_fulfillment_type text,
  p_delivery_address text,
  p_notes text,
  p_location text,
  p_psid text,
  p_token text,
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
  v_token text := nullif(trim(coalesce(p_token, '')), '');
  v_consumed_token text;
  v_line jsonb;
  v_total numeric(18, 4) := 0;
  v_qty int;
  v_price numeric(18, 4);
  v_item_code text;
  v_line_count int := 0;
  v_recent_order_count int;
  -- Tunable in one place if the threshold/window ever needs adjusting.
  v_rate_limit_max_orders constant int := 3;
  v_rate_limit_window constant interval := interval '10 minutes';
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

  -- Rate limit - see supabase_automated_order_rate_limit.sql's file header. Checked early, before
  -- any of the heavier validation/insert work below, so a flood of calls fails fast rather than
  -- still paying for line-item/price lookups.
  select count(*) into v_recent_order_count
  from public."AutomatedOrders"
  where regexp_replace("CustomerPhone", '[^0-9]', '', 'g') = regexp_replace(p_customer_phone, '[^0-9]', '', 'g')
    and "CreatedAtUtc" > now() - v_rate_limit_window;

  if v_recent_order_count >= v_rate_limit_max_orders then
    raise exception 'You''ve already submitted a few orders recently. Please wait a few minutes, or contact us directly if this is urgent.';
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

  if v_psid is not null then
    if v_token is not null then
      -- Atomically consume the token - single UPDATE with "ConsumedAtUtc is null" in the WHERE
      -- clause is what makes this race-safe (two simultaneous submissions racing for the same
      -- token can never both succeed; Postgres serializes the two UPDATEs against the same row).
      -- Only a token that's unexpired and not already consumed by an earlier submission counts.
      update public."OrderNowSessionTokens"
      set "ConsumedAtUtc" = now(), "ConsumedByOrderNo" = v_order_no
      where "Token" = v_token
        and "Psid" = v_psid
        and "ConsumedAtUtc" is null
        and "ExpiresAtUtc" > now()
      returning "Token" into v_consumed_token;

      if v_consumed_token is null then
        v_psid := null;
      end if;
    else
      -- No token at all (should be rare - JS disabled, or a cached page load from before this
      -- shipped). No way to verify the psid without one, so drop it rather than guess - safe
      -- default, and the order still submits normally either way.
      v_psid := null;
    end if;
  end if;

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

    -- Price-validation fix (see supabase_automated_order_psid_verification.sql): a real catalog
    -- item_code always gets its price looked up server-side, never taken from the client. Only a
    -- line with no item_code at all (a Customize-flow calculated quote) falls back to the
    -- client-submitted price.
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

grant execute on function public.submit_automated_order(text, text, text, text, text, text, text, text, text, jsonb) to anon;
