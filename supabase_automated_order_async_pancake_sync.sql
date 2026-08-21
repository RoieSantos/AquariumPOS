-- Decouples Order Now's customer-facing response from Pancake - per direct follow-up to "will
-- multiple users on Order Now at once have any traffic issues": submit_automated_order() used to
-- call _push_automated_order_to_pancake() and _send_order_confirmation_message() SYNCHRONOUSLY
-- before returning, so every customer's "Order Confirmed" screen waited on a live Pancake API
-- round-trip (order create + a messaging API call) on top of the local insert. That's not a data-
-- collision risk (order numbers are already race-condition-safe via _next_no_series_number's
-- atomic UPDATE...RETURNING), but it does mean response time scales with Pancake's own latency -
-- under a real concurrent spike, customers would wait longer than the local database work alone
-- would ever take.
--
-- This file redefines submit_automated_order to do ONLY the local insert and return immediately -
-- new orders sit at PancakeSyncStatus = 'Pending' (already the column's default).
--
-- The actual Pancake push is now driven by the customer's OWN browser, not the server: right after
-- submit_automated_order returns, js/orderNow.js fires public_sync_automated_order_to_pancake()
-- WITHOUT awaiting it, so the confirmation screen renders immediately while that request runs in
-- the background - in the normal case this still resolves in a second or two, the customer just
-- never has to wait on it. js/orderNow.js then briefly polls public_get_automated_order_status() to
-- reveal the real Pancake order number on the already-shown confirmation screen once it lands.
--
-- A pg_cron job (same cron.schedule/unschedule pattern already used for
-- cron_sync_online_customers_from_pancake etc. - see supabase_online_customers_table.sql) is kept
-- purely as a once-a-minute SAFETY NET for the rare case the browser-driven call never landed (tab
-- closed instantly, network hiccup) - not the primary path, so the "up to 1 minute" wait is now an
-- edge case rather than what every order goes through.

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

  insert into public."AutomatedOrders"
    ("OrderNo", "CustomerName", "CustomerPhone", "CustomerEmail", "FulfillmentType", "DeliveryAddress", "Notes", "Status", "EstimatedTotal", "Location", "Psid")
  values
    (v_order_no, trim(p_customer_name), trim(p_customer_phone), nullif(trim(coalesce(p_customer_email, '')), ''),
     v_fulfillment, case when v_fulfillment = 'Delivery' then trim(p_delivery_address) else null end,
     nullif(trim(coalesce(p_notes, '')), ''), 'New', 0, v_location, v_psid);

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_qty := greatest(coalesce((v_line->>'quantity')::int, 1), 1);
    v_price := greatest(coalesce((v_line->>'price')::numeric, 0), 0);

    if v_line->>'item_name' is null or trim(v_line->>'item_name') = '' then
      raise exception 'Each order line requires an item name.';
    end if;

    insert into public."AutomatedOrderLines"
      ("OrderNo", "CategoryCode", "ItemCode", "ItemName", "Quantity", "Price")
    values
      (v_order_no, nullif(trim(coalesce(v_line->>'category_code', '')), ''),
       nullif(trim(coalesce(v_line->>'item_code', '')), ''), trim(v_line->>'item_name'), v_qty, v_price);

    v_total := v_total + (v_qty * v_price);
    v_line_count := v_line_count + 1;
  end loop;

  update public."AutomatedOrders" set "EstimatedTotal" = v_total where "OrderNo" = v_order_no;

  -- Pancake push + confirmation message deliberately NOT called here anymore - see file header.
  -- The row stays at its default PancakeSyncStatus = 'Pending' and cron_process_pending_
  -- automated_orders() (below) picks it up within a minute.

  return query
    select o."OrderNo"::text, o."PancakeOrderId"::text, o."PancakeSyncStatus"::text
    from public."AutomatedOrders" o
    where o."OrderNo" = v_order_no;
end;
$$;

grant execute on function public.submit_automated_order(text, text, text, text, text, text, text, text, jsonb) to anon;

-- ---------------------------------------------------------------------------
-- Browser-driven sync trigger - js/orderNow.js calls this right after submit_automated_order
-- WITHOUT awaiting it, so the confirmation screen never blocks on it. Guarded to only act on an
-- order that's still 'Pending': _push_automated_order_to_pancake always resolves to Synced/Failed,
-- so calling it again on an already-Synced order would create a SECOND order in Pancake (same
-- guard reasoning as the existing staff "Retry Push to Pancake" button, which is likewise
-- restricted to Failed orders only) - this just makes double-calls (e.g. a slow first call plus a
-- retry) harmless no-ops instead of duplicate Pancake orders.
--
-- Open to anon like submit_automated_order itself (Order Now has no login to check an owner
-- against) - the only thing a caller can do with an arbitrary order_no is nudge an already-pending
-- sync to happen slightly sooner than the cron sweep would anyway, not read or change anything.
-- ---------------------------------------------------------------------------

drop function if exists public.public_sync_automated_order_to_pancake(text);

create or replace function public.public_sync_automated_order_to_pancake(p_order_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if exists (
    select 1 from public."AutomatedOrders"
    where "OrderNo" = p_order_no and "PancakeSyncStatus" = 'Pending'
  ) then
    perform public._push_automated_order_to_pancake(p_order_no);
    perform public._send_order_confirmation_message(p_order_no);
  end if;
end;
$$;

grant execute on function public.public_sync_automated_order_to_pancake(text) to anon;

drop function if exists public.public_get_automated_order_status(text);

-- Light read-only poll for js/orderNow.js's confirmation screen (see file header) - only exposes
-- sync status/the Pancake order id, nothing sensitive, same exposure class as the order_no/
-- pancake_order_id submit_automated_order already returns to anon.
create or replace function public.public_get_automated_order_status(p_order_no text)
returns table(pancake_sync_status text, pancake_order_id text)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "PancakeSyncStatus"::text, "PancakeOrderId"::text
  from public."AutomatedOrders"
  where "OrderNo" = p_order_no;
$$;

grant execute on function public.public_get_automated_order_status(text) to anon;

-- ---------------------------------------------------------------------------
-- Background sweep - runs the same two worker functions submit_automated_order used to call
-- inline, now on a timer instead. Batch-limited (25 per run) so one run can never take long enough
-- to bump into the next run or approach a statement timeout; anything left over just gets picked up
-- on the next pass a minute later.
-- ---------------------------------------------------------------------------

drop function if exists public.cron_process_pending_automated_orders();

create or replace function public.cron_process_pending_automated_orders()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order_no text;
begin
  for v_order_no in
    select "OrderNo" from public."AutomatedOrders"
    where "PancakeSyncStatus" = 'Pending'
    order by "EntryNo"
    limit 25
  loop
    perform public._push_automated_order_to_pancake(v_order_no);
    perform public._send_order_confirmation_message(v_order_no);
  end loop;
end;
$$;

-- No grant to anon - called directly by pg_cron inside Postgres, never through PostgREST (same as
-- cron_sync_online_customers_from_pancake/cron_sync_items_from_pancake).

do $$
begin
  perform cron.unschedule('process-pending-automated-orders');
exception when others then
  null; -- job didn't exist yet - nothing to unschedule
end;
$$;

select cron.schedule(
  'process-pending-automated-orders',
  '* * * * *',
  $$select public.cron_process_pending_automated_orders();$$
);
