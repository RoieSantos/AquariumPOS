-- Follow-up to supabase_automated_order_psid_verification.sql's anti link-sharing check, which
-- only works when Pancake has already synced a phone number for the psid - per direct discussion,
-- that's not reliable enough on its own (plenty of customers place their first order with no phone
-- on file yet, and that case fell back to "whoever submits first under this psid wins", forever,
-- with no time bound at all).
--
-- This replaces that phone dependency with a one-time SESSION TOKEN instead - it works identically
-- regardless of whether Pancake has any phone/customer data synced at all, because it's tied to
-- the BROWSER SESSION that loaded the personalized link, not to any Pancake record.
--
-- How it works (see js/orderNow.js's captureMessengerPsid for the client side):
--   1. Botcake's actual Messenger button always links to a plain "?psid=X" URL (it has no idea
--      about our token scheme) - so every genuine click from Messenger is a "clean" URL with no
--      token param at all.
--   2. On a clean psid-only load, the page calls public_issue_order_now_session_token(psid), which
--      mints a fresh one-time token UNLESS an active (unconsumed, unexpired) one already exists
--      for this exact psid - in that case it returns that SAME existing token instead. This is
--      what closes the bare-link sharing case: without it, forwarding a plain "?psid=X" link (no
--      token yet) would just mint the recipient their own equally-valid fresh token on their own
--      page load, same as before the token scheme existed at all. With it, two different people
--      loading the same bare link within the token's active window both end up holding the
--      IDENTICAL token. Either way, the page then rewrites the address bar (history.replaceState)
--      to "?psid=X&token=T" - so anything copied FROM THAT POINT ON carries the token too.
--   3. If the page instead loads with a token ALREADY in the URL (a copied/forwarded link that's
--      already been through step 2 once), it reuses that token as-is and never asks for a new one.
--   4. submit_automated_order atomically consumes the token (single-use) and only trusts the psid
--      if it was valid, unexpired, and not already consumed by an earlier submission.
--
-- Because Botcake's button is always tokenless, a customer's own REPEAT legitimate use (clicking
-- "Order Now" again weeks later for a separate order) is completely unaffected - by then any
-- earlier token has long since expired (2 hours), so step 2 mints a genuinely fresh one. Anyone
-- who ends up sharing a token with someone else - whether by forwarding a bare psid-only link that
-- resolves to the same active token, or an already-tokened URL - can only have it consumed
-- successfully by whichever submission reaches the server first; the loser's order still goes
-- through fine, just without the psid attachment, same graceful-degrade contract as every other
-- case here.
--
-- Kept as a SEPARATE table/mechanism from the phone check rather than replacing it outright - the
-- phone check now only matters as a fallback for the (should be rare) case a token never got
-- minted at all, e.g. JavaScript disabled or a very old cached page load from before this shipped.
create table if not exists public."OrderNowSessionTokens" (
  "Token" varchar(64) primary key,
  "Psid" varchar(255) not null,
  "CreatedAtUtc" timestamptz not null default now(),
  "ExpiresAtUtc" timestamptz not null,
  "ConsumedAtUtc" timestamptz,
  "ConsumedByOrderNo" varchar(50)
);

create index if not exists "IX_OrderNowSessionTokens_Psid" on public."OrderNowSessionTokens" ("Psid");

alter table public."OrderNowSessionTokens" enable row level security;
revoke all on public."OrderNowSessionTokens" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Mints a one-time token for a clean psid-only page load - see file header. Idempotent PER PSID
-- (not per call): if an active token already exists for this psid, that same one is returned
-- instead of minting a new one, so two different people loading the same bare "?psid=X" link both
-- end up racing for the identical token rather than each getting their own guaranteed-valid one.
-- 2-hour expiry is generous for a customer who takes a while deciding what to order, while still
-- bounding how long a token stays exploitable by anyone else who ends up with a copy of it.
--
-- Narrow, accepted race: two requests for the same psid arriving at the exact same instant could
-- both miss each other's not-yet-committed insert below and mint two separate tokens - this needs
-- literally-simultaneous page loads to happen at all, and even then it just falls back to the
-- pre-idempotency behavior for that one pair, never blocks or breaks an order. Not worth a
-- SELECT ... FOR UPDATE/advisory lock for that likelihood.
-- ---------------------------------------------------------------------------

drop function if exists public.public_issue_order_now_session_token(text);

create or replace function public.public_issue_order_now_session_token(p_psid text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_psid text := nullif(trim(coalesce(p_psid, '')), '');
  v_token text;
begin
  if v_psid is null then
    return null;
  end if;

  select "Token" into v_token
  from public."OrderNowSessionTokens"
  where "Psid" = v_psid
    and "ConsumedAtUtc" is null
    and "ExpiresAtUtc" > now()
  order by "CreatedAtUtc" desc
  limit 1;

  if v_token is not null then
    return v_token;
  end if;

  v_token := replace(gen_random_uuid()::text, '-', '');

  insert into public."OrderNowSessionTokens" ("Token", "Psid", "ExpiresAtUtc")
  values (v_token, v_psid, now() + interval '2 hours');

  return v_token;
end;
$$;

grant execute on function public.public_issue_order_now_session_token(text) to anon;

-- ---------------------------------------------------------------------------
-- submit_automated_order - adds p_token, consumed atomically (single-use) as the primary
-- anti link-sharing check; falls back to the phone-match check from supabase_automated_order_
-- psid_verification.sql only when no token was ever provided at all.
-- ---------------------------------------------------------------------------
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

  v_order_no := public._next_no_series_number('AUTOMATED-ORDER', '');

  if v_psid is not null then
    if v_token is not null then
      -- Primary check: atomically consume the token - single UPDATE with "ConsumedAtUtc is null"
      -- in the WHERE clause is what makes this race-safe (two simultaneous submissions racing for
      -- the same token can never both succeed; Postgres serializes the two UPDATEs against the
      -- same row). Only a token that's unexpired and not already consumed by an earlier
      -- submission counts.
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
      -- Fallback for the (should be rare) case no token was ever minted for this visit at all -
      -- e.g. JavaScript disabled, or a cached page load from before this shipped. Same phone-match
      -- logic as supabase_automated_order_psid_verification.sql.
      if exists (
        select 1 from public."OnlineCustomers" c
        where (c."FbID" = v_psid or c."FbID" = '195716644410829_' || v_psid)
          and nullif(trim(coalesce(c."PrimaryPhoneNumber", '')), '') is not null
      ) then
        if not exists (
          select 1 from public."OnlineCustomers" c
          where (c."FbID" = v_psid or c."FbID" = '195716644410829_' || v_psid)
            and regexp_replace(c."PrimaryPhoneNumber", '[^0-9]', '', 'g') = regexp_replace(p_customer_phone, '[^0-9]', '', 'g')
        ) then
          v_psid := null;
        end if;
      else
        if exists (
          select 1 from public."AutomatedOrders" ao
          where ao."Psid" = v_psid
            and regexp_replace(coalesce(ao."CustomerPhone", ''), '[^0-9]', '', 'g') <> regexp_replace(p_customer_phone, '[^0-9]', '', 'g')
        ) then
          v_psid := null;
        end if;
      end if;
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
