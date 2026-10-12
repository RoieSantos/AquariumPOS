-- Pinned-location deliveries, end to end - per "once they send this [📍 My delivery location].. link this to
-- the delivery calendar.. book to the calendar for a specific date and order id", "show the price too base on
-- the customer's pin.. auto populate the delivery fee on that order and calendar", and the automated flow
-- ("Vic sends the pin link, customer pins, the pin is saved to the order, Vic replies with the fee and dates,
-- the customer picks one and Vic books it; a re-pin moves the existing stop and staff get notified").
--
--   1. Columns: AutomatedOrders.DeliveryLatitude / DeliveryLongitude / DeliveryLandmark (the order's pin);
--      ChatbotLocationRequests.AppliedOrderNo / BotNotifiedAtUtc.
--   2. _book_delivery_stop_core - ONE booking routine for staff and Vic: moves the order's upcoming
--      (not done) stop if it has one - never a second stop - else creates it (same truck / route /
--      sequence rules as the Delivery page); puts the pin + fee on the stop; puts the fee (+ pin) on the
--      order (draft GMA order: fee, total, address; confirmed Portal order: fee, amount to collect,
--      balance; Pancake order: fee left alone, fee_note says so).
--   3. admin_book_delivery_from_pin (staff 📅 button) and service_book_delivery_from_pin (Vic - 2 days'
--      notice, no Mondays, same as his existing self-booking) on top of it.
--   4. _apply_pin_to_chat_order + public_submit_location_request re-created: a submitted pin is saved to
--      the chat's open delivery order right away - unless that order is already booked: then the new pin
--      waits (NeedsConfirmation) until the customer confirms it in Messenger or staff book it with 📅, and
--      staff get a Telegram message. Link safety (per "is this link expiring.. if the customer copy and
--      send this link to anyone"): public_get_location_request no longer returns the name / saved pin, and
--      a link works for 48 hours after it's sent and 24 hours after its first pin.
--   5. service_claim_pin_bot_notify - lets facebook-messenger-webhook (?task=pin-submitted) wake Vic once
--      per submitted pin, so he replies with the fee + dates.
--
-- Run AFTER supabase_gma_location_pin.sql. Safe to re-run.
-- Needs: facebook-messenger-webhook + delivery-fee-from-pin deployed, docs/pin-location.html, and
-- js/gmaConversations.js ?v=pinsafe1.

-- 1. -------------------------------------------------------------------------
alter table public."AutomatedOrders" add column if not exists "DeliveryLatitude" numeric;
alter table public."AutomatedOrders" add column if not exists "DeliveryLongitude" numeric;
alter table public."AutomatedOrders" add column if not exists "DeliveryLandmark" text;
alter table public."ChatbotLocationRequests" add column if not exists "AppliedOrderNo" text;
alter table public."ChatbotLocationRequests" add column if not exists "BotNotifiedAtUtc" timestamptz;
-- Link safety (a customer may forward the link): FirstSubmittedAtUtc drives the shorter expiry, and a re-pin
-- on an already-booked order waits in NeedsConfirmation until the customer confirms it in Messenger.
alter table public."ChatbotLocationRequests" add column if not exists "FirstSubmittedAtUtc" timestamptz;
alter table public."ChatbotLocationRequests" add column if not exists "NeedsConfirmation" boolean not null default false;

-- 2. -------------------------------------------------------------------------
create or replace function public._book_delivery_stop_core(
  p_order_no text,
  p_delivery_date date,
  p_latitude numeric,
  p_longitude numeric,
  p_address text,
  p_notes text,
  p_delivery_fee numeric,     -- null = don't touch any fee
  p_actor text
)
returns table(stop_id uuid, moved boolean, fee_note text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_address text := nullif(trim(coalesce(p_address, '')), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_fee numeric(18, 2) := round(p_delivery_fee, 2);
  v_has_pin boolean := p_latitude is not null and p_longitude is not null;
  v_ao public."AutomatedOrders"%rowtype;
  v_online public."OnlineOrders"%rowtype;
  v_has_online boolean := false;
  v_online_status text;
  v_stop_id uuid;
  v_old_date date;
  v_moved boolean := false;
  v_truck_id uuid;
  v_seq int;
  v_route text;
  v_delta numeric(18, 2);
  v_fee_note text;
begin
  if p_delivery_date is null then
    raise exception 'A delivery date is required.';
  end if;
  if p_delivery_date < v_today then
    raise exception 'That date has already passed.';
  end if;
  if v_fee is not null and v_fee < 0 then
    raise exception 'Delivery fee can''t be negative.';
  end if;

  select * into v_ao from public."AutomatedOrders" where "OrderNo" = trim(p_order_no) for update;
  if not found then
    raise exception 'Order % not found.', p_order_no;
  end if;
  if v_ao."Status" in ('Completed', 'Cancelled') then
    raise exception 'Order % is % - it can''t be scheduled for delivery.', v_ao."OrderNo", v_ao."Status";
  end if;
  select * into v_online from public."OnlineOrders" where "OrderID" = nullif(trim(v_ao."PancakeReceiptNo"), '');
  v_has_online := found;
  if v_has_online then
    v_online_status := lower(trim(coalesce(v_online."Status", '')));
    if v_online_status in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning') then
      raise exception 'Order % is already %.', v_ao."OrderNo", v_online."Status";
    end if;
  end if;

  -- The stop: move the order's upcoming, not-done stop if it has one; else create it.
  select s."StopID", s."DeliveryDate" into v_stop_id, v_old_date
  from public."DeliveryStops" s
  where (s."AutomatedOrderNo" = v_ao."OrderNo" or (v_has_online and s."OrderID" = v_online."OrderID"))
    and s."DeliveryDate" >= v_today
    and not exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID")
  order by s."DeliveryDate"
  limit 1;

  select "RouteName" into v_route from public."DeliveryRouteSchedule" where "DayOfWeek" = extract(dow from p_delivery_date);

  -- The stop, in ONE write: every insert/update of a stop fires trg_notify_delivery_stop_changed, which
  -- sends the delivery team a web push as a live HTTP call (_trigger_web_push) - two writes meant two
  -- calls and ran past the request's time limit ("canceling statement due to statement timeout").
  if v_stop_id is not null then
    -- Move the order's upcoming, not-done stop (new date and/or pin + fee) - never a second stop.
    v_moved := true;
    if v_old_date <> p_delivery_date then
      select "TruckID" into v_truck_id from public."DeliveryStops" where "StopID" = v_stop_id;
      select coalesce(max("StopSequence") + 1, 0) into v_seq
      from public."DeliveryStops" where "DeliveryDate" = p_delivery_date and "TruckID" = v_truck_id and "StopID" <> v_stop_id;
    end if;
    begin
      update public."DeliveryStops"
         set "DeliveryDate" = p_delivery_date,
             "StopSequence" = case when v_old_date <> p_delivery_date then v_seq else "StopSequence" end,
             "RouteName" = case when v_old_date <> p_delivery_date then v_route else "RouteName" end,
             "Notes" = case when v_notes is not null then 'Landmark: ' || v_notes else "Notes" end,
             "Latitude" = case when v_has_pin then p_latitude else "Latitude" end,
             "Longitude" = case when v_has_pin then p_longitude else "Longitude" end,
             "GeocodeStatus" = case when v_has_pin then 'ok' else "GeocodeStatus" end,
             "GeocodedAddress" = case when v_has_pin then coalesce(v_address, round(p_latitude, 6) || ',' || round(p_longitude, 6)) else "GeocodedAddress" end,
             "GeocodedAtUtc" = case when v_has_pin then now() else "GeocodedAtUtc" end,
             "ManualAddress" = coalesce(v_address, "ManualAddress"),
             "ManualDeliveryFee" = coalesce(v_fee, "ManualDeliveryFee")
       where "StopID" = v_stop_id;
    exception when unique_violation then
      raise exception 'This order is already scheduled for that date.';
    end;
  else
    -- New stop (same truck / sequence / route rules as the Delivery page), pin + fee included.
    select "TruckID" into v_truck_id from public."DeliveryTrucks" where "IsActive" is true order by "CreatedAtUtc" limit 1;
    if v_truck_id is null then
      raise exception 'No active delivery truck is configured.';
    end if;
    select coalesce(max("StopSequence") + 1, 0) into v_seq
    from public."DeliveryStops" where "DeliveryDate" = p_delivery_date and "TruckID" = v_truck_id;
    begin
      insert into public."DeliveryStops" (
        "OrderID", "AutomatedOrderNo", "TruckID", "DeliveryDate", "StopSequence", "Notes", "CreatedBy", "RouteName",
        "Latitude", "Longitude", "GeocodeStatus", "GeocodedAddress", "GeocodedAtUtc", "ManualAddress", "ManualDeliveryFee")
      values (
        case when v_has_online then v_online."OrderID" end,
        case when not v_has_online then v_ao."OrderNo" end,
        v_truck_id, p_delivery_date, v_seq,
        case when v_notes is not null then 'Landmark: ' || v_notes end,
        p_actor, v_route,
        case when v_has_pin then p_latitude end,
        case when v_has_pin then p_longitude end,
        case when v_has_pin then 'ok' end,
        case when v_has_pin then coalesce(v_address, round(p_latitude, 6) || ',' || round(p_longitude, 6)) end,
        case when v_has_pin then now() end,
        v_address, v_fee)
      returning "StopID" into v_stop_id;
    exception when unique_violation then
      raise exception 'This order is already scheduled for that date.';
    end;
    if v_has_online then
      update public."OnlineOrders" set "ForDelivery" = true where "OrderID" = v_online."OrderID";
    end if;
  end if;

  -- Pin on the order. Booking WITH a pending re-pin (staff 📅 on it, or the customer confirmed it) settles it.
  if v_has_pin then
    update public."AutomatedOrders"
       set "DeliveryLatitude" = p_latitude, "DeliveryLongitude" = p_longitude,
           "DeliveryLandmark" = coalesce(v_notes, "DeliveryLandmark")
     where "OrderNo" = v_ao."OrderNo";
    update public."ChatbotLocationRequests"
       set "NeedsConfirmation" = false
     where "AppliedOrderNo" = v_ao."OrderNo" and "NeedsConfirmation"
       and round("Latitude"::numeric, 6) = round(p_latitude, 6) and round("Longitude"::numeric, 6) = round(p_longitude, 6);
  end if;

  -- Fee on the order.
  if v_fee is not null then
    if v_has_online then
      if coalesce(v_online."Source", '') <> 'Portal' then
        v_fee_note := 'Booked, but order ' || v_ao."OrderNo" || ' is a Pancake order - set its delivery fee in Pancake.';
      else
        -- Same as admin_set_portal_order_delivery_fee (Online Orders' editable Delivery Fee).
        v_delta := v_fee - coalesce(v_online."DeliveryFee", 0);
        update public."OnlineOrders"
           set "DeliveryFee" = nullif(v_fee, 0),
               "MoneyToCollect" = coalesce("MoneyToCollect", 0) + v_delta,
               "Balance" = coalesce("Balance", 0) + v_delta,
               "ForDelivery" = true,
               "Last_Updated_At" = now()
         where "OrderID" = v_online."OrderID";
        update public."AutomatedOrders"
           set "DeliveryFee" = v_fee, "EstimatedTotal" = coalesce("EstimatedTotal", 0) + v_delta, "UpdatedAtUtc" = now()
         where "OrderNo" = v_ao."OrderNo";
        v_fee_note := 'Delivery fee set on Online Order ' || v_online."OrderID" || '.';
      end if;
    elsif coalesce(v_ao."PancakeSyncStatus", 'Not Pushed') = 'Not Pushed' then
      update public."AutomatedOrders"
         set "DeliveryFee" = v_fee,
             "EstimatedTotal" = coalesce("EstimatedTotal", 0) - coalesce("DeliveryFee", 0) + v_fee,
             "FulfillmentType" = 'Delivery',
             "DeliveryAddress" = coalesce(v_address, "DeliveryAddress"),
             "UpdatedAtUtc" = now()
       where "OrderNo" = v_ao."OrderNo";
      v_fee_note := 'Delivery fee set on order ' || v_ao."OrderNo" || '.';
    else
      v_fee_note := 'Booked, but order ' || v_ao."OrderNo" || ' is a Pancake order - set its delivery fee in Pancake.';
    end if;
  end if;

  return query select v_stop_id, v_moved, v_fee_note;
end;
$$;

revoke all on function public._book_delivery_stop_core(text, date, numeric, numeric, text, text, numeric, text) from public, anon, authenticated;

-- 3. -------------------------------------------------------------------------
-- Staff (GMA Conversations' "Book this date").
drop function if exists public.admin_book_delivery_from_pin(text, text, text, date, numeric, numeric, text, text);

create or replace function public.admin_book_delivery_from_pin(
  p_admin_username text,
  p_admin_password text,
  p_order_no text,
  p_delivery_date date,
  p_latitude numeric,
  p_longitude numeric,
  p_address text default null,
  p_notes text default null,
  p_delivery_fee numeric default null
)
returns table(stop_id uuid, moved boolean, fee_note text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_latitude is null or p_longitude is null then
    raise exception 'The pinned location has no coordinates.';
  end if;
  return query select * from public._book_delivery_stop_core(
    p_order_no, p_delivery_date, p_latitude, p_longitude, p_address, p_notes, p_delivery_fee, p_admin_username);
end;
$$;

grant execute on function public.admin_book_delivery_from_pin(text, text, text, date, numeric, numeric, text, text, numeric) to anon;

-- Vic (schedule_delivery_date, chatbot-engine.ts) - same rules as his existing self-booking. The pin is
-- optional (no pin yet = the stop is geocoded from the address as usual).
create or replace function public.service_book_delivery_from_pin(
  p_order_no text,
  p_delivery_date date,
  p_latitude numeric,
  p_longitude numeric,
  p_address text,
  p_notes text,
  p_delivery_fee numeric
)
returns table(stop_id uuid, moved boolean, fee_note text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if p_delivery_date < (now() at time zone 'Asia/Manila')::date + 2 then
    raise exception 'Delivery dates need at least 2 days notice.';
  end if;
  if extract(dow from p_delivery_date) = 1 then
    raise exception 'Mondays are not available for delivery.';
  end if;
  return query select * from public._book_delivery_stop_core(
    p_order_no, p_delivery_date, p_latitude, p_longitude, p_address, p_notes, p_delivery_fee, 'AI Assistant (Messenger)');
end;
$$;

revoke all on function public.service_book_delivery_from_pin(text, date, numeric, numeric, text, text, numeric) from public, anon, authenticated;
grant execute on function public.service_book_delivery_from_pin(text, date, numeric, numeric, text, text, numeric) to service_role;

-- 4. -------------------------------------------------------------------------
-- A submitted pin -> the chat's open delivery order (newest not Completed / Cancelled / Pickup, not shipped).
--   * order NOT booked yet: the pin goes on the order right away (coordinates, landmark, draft address);
--   * order ALREADY booked: nothing changes yet - the pin waits (needs_confirmation) until the customer
--     confirms it in Messenger (Vic: schedule_delivery_date confirm_new_pin) or staff book it with 📅 -
--     a forwarded link can't move a booked delivery. Staff get a Telegram message either way.
-- Returns the order (null = no open order yet).
drop function if exists public._apply_pin_to_chat_order(text, numeric, numeric, text, text);

create or replace function public._apply_pin_to_chat_order(
  p_psid text, p_latitude numeric, p_longitude numeric, p_address text, p_notes text
)
returns table(order_no text, needs_confirmation boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_address text := nullif(trim(coalesce(p_address, '')), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_ao public."AutomatedOrders"%rowtype;
  v_online_id text;
  v_stop_date date;
begin
  select ao.* into v_ao
  from public."AutomatedOrders" ao
  left join public."OnlineOrders" o on o."OrderID" = nullif(trim(ao."PancakeReceiptNo"), '')
  where ao."GmaPsid" = p_psid
    and coalesce(ao."Status", '') not in ('Completed', 'Cancelled')
    and coalesce(ao."FulfillmentType", 'Delivery') <> 'Pickup'
    and lower(trim(coalesce(o."Status", ''))) not in ('shipped', 'delivered', 'completed', 'cancelled', 'canceled', 'returned', 'returning')
  order by ao."CreatedAtUtc" desc nulls last
  limit 1;
  if not found then
    return query select null::text, false;
    return;
  end if;
  select o."OrderID" into v_online_id from public."OnlineOrders" o where o."OrderID" = nullif(trim(v_ao."PancakeReceiptNo"), '');

  select s."DeliveryDate" into v_stop_date
  from public."DeliveryStops" s
  where (s."AutomatedOrderNo" = v_ao."OrderNo" or (v_online_id is not null and s."OrderID" = v_online_id))
    and s."DeliveryDate" >= v_today
    and not exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID")
  order by s."DeliveryDate"
  limit 1;

  if v_stop_date is not null then
    -- Staff hear about it from facebook-messenger-webhook's pin-submitted task (Telegram), NOT from here: a
    -- live HTTP call inside this anon request could run past its time limit and lose the customer's pin.
    return query select v_ao."OrderNo"::text, true;
    return;
  end if;

  update public."AutomatedOrders"
     set "DeliveryLatitude" = p_latitude, "DeliveryLongitude" = p_longitude,
         "DeliveryLandmark" = coalesce(v_notes, "DeliveryLandmark"),
         -- Draft only - a confirmed order's address lives on its Online Order / delivery stop.
         "DeliveryAddress" = case when coalesce("PancakeSyncStatus", 'Not Pushed') = 'Not Pushed'
                                  then coalesce(v_address, "DeliveryAddress") else "DeliveryAddress" end
   where "OrderNo" = v_ao."OrderNo";
  return query select v_ao."OrderNo"::text, false;
end;
$$;

revoke all on function public._apply_pin_to_chat_order(text, numeric, numeric, text, text) from public, anon, authenticated;

-- Link safety - the link may get forwarded:
--   * nothing about the customer comes back (no name, no saved address / pin) - a re-opened link is a blank map;
--   * a link works for 48 hours after it was sent, and for 24 hours after its first pin (to fix a wrong
--     pin), max 5 pins.
-- Same signature as supabase_gma_location_pin.sql (the name / pin columns now always come back empty).
create or replace function public.public_get_location_request(p_token uuid)
returns table(status text, customer_name text, latitude double precision, longitude double precision, address text, notes text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."ChatbotLocationRequests";
  v_status text := 'ok';
begin
  select * into v_row from public."ChatbotLocationRequests" where "Token" = p_token;
  if not found then
    v_status := 'not_found';
  elsif (v_row."FirstSubmittedAtUtc" is null and v_row."RequestedAtUtc" < now() - interval '48 hours')
        or v_row."FirstSubmittedAtUtc" < now() - interval '24 hours' then
    v_status := 'expired';
  elsif v_row."SubmitCount" >= 5 then
    v_status := 'limit';
  end if;
  return query select v_status, null::text, null::double precision, null::double precision, null::text, null::text;
end;
$$;

grant execute on function public.public_get_location_request(uuid) to anon;

-- Same as supabase_gma_location_pin.sql, plus: the expiry above, and the pin is applied to the chat's open
-- order (or held for confirmation - _apply_pin_to_chat_order).
create or replace function public.public_submit_location_request(
  p_token uuid, p_latitude double precision, p_longitude double precision, p_address text, p_notes text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."ChatbotLocationRequests";
  v_address text := left(nullif(trim(coalesce(p_address, '')), ''), 500);
  v_notes text := left(nullif(trim(coalesce(p_notes, '')), ''), 500);
  v_content text;
  v_applied record;
begin
  select * into v_row from public."ChatbotLocationRequests" where "Token" = p_token for update;
  if not found then
    raise exception 'This link is not valid. Please ask us for a new one.';
  end if;
  if (v_row."FirstSubmittedAtUtc" is null and v_row."RequestedAtUtc" < now() - interval '48 hours')
     or v_row."FirstSubmittedAtUtc" < now() - interval '24 hours' then
    raise exception 'This link has expired. Please ask us in Messenger for a new one.';
  end if;
  if v_row."SubmitCount" >= 5 then
    raise exception 'This link was already used several times. Please message us if your location changed.';
  end if;
  if p_latitude is null or p_longitude is null
     or p_latitude not between 4.0 and 21.5 or p_longitude not between 116.0 and 127.0 then
    raise exception 'Please drop the pin on your location in the Philippines.';
  end if;

  v_content := '📍 My delivery location' || case when v_row."SubmitCount" > 0 then ' (updated)' else '' end || E':\n'
    || coalesce(v_address || E'\n', '')
    || coalesce('Landmark / notes: ' || v_notes || E'\n', '')
    || 'https://www.google.com/maps?q=' || round(p_latitude::numeric, 6) || ',' || round(p_longitude::numeric, 6);

  insert into public."ChatbotMessages" ("Psid", "Role", "Content") values (v_row."Psid", 'user', v_content);
  update public."ChatbotConversations"
     set "LastMessageAtUtc" = now(), "LastCustomerMessageAtUtc" = now()
   where "Psid" = v_row."Psid";

  select * into v_applied from public._apply_pin_to_chat_order(v_row."Psid", p_latitude::numeric, p_longitude::numeric, v_address, v_notes);

  -- Only one pin per order waits for confirmation - the newest.
  if v_applied.needs_confirmation then
    update public."ChatbotLocationRequests" set "NeedsConfirmation" = false
     where "AppliedOrderNo" = v_applied.order_no and "NeedsConfirmation";
  end if;

  update public."ChatbotLocationRequests"
     set "Latitude" = p_latitude, "Longitude" = p_longitude, "Address" = v_address, "Notes" = v_notes,
         "SubmittedAtUtc" = now(), "FirstSubmittedAtUtc" = coalesce("FirstSubmittedAtUtc", now()),
         "SubmitCount" = "SubmitCount" + 1,
         "AppliedOrderNo" = v_applied.order_no, "NeedsConfirmation" = coalesce(v_applied.needs_confirmation, false)
   where "Token" = p_token;

  return v_row."Psid";
end;
$$;

grant execute on function public.public_submit_location_request(uuid, double precision, double precision, text, text) to anon;

-- 5. -------------------------------------------------------------------------
-- Once per submitted pin, within 5 minutes of it: returns the chat's Psid for the webhook to wake Vic,
-- null otherwise (already done / stale / unknown token).
create or replace function public.service_claim_pin_bot_notify(p_token uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_psid text;
begin
  update public."ChatbotLocationRequests"
     set "BotNotifiedAtUtc" = now()
   where "Token" = p_token
     and "SubmittedAtUtc" > now() - interval '5 minutes'
     and ("BotNotifiedAtUtc" is null or "BotNotifiedAtUtc" < "SubmittedAtUtc")
  returning "Psid" into v_psid;
  return v_psid;
end;
$$;

revoke all on function public.service_claim_pin_bot_notify(uuid) from public, anon, authenticated;
grant execute on function public.service_claim_pin_bot_notify(uuid) to service_role;

notify pgrst, 'reload schema';
