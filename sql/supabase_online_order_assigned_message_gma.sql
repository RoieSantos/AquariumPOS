-- "In production" message for GMA Page orders too - per "on online orders i want to detect if its from
-- GMA PAGE then we will send message base on the status of the order ... Confirmed orders > Assigned
-- (Once assigned automatically send the message to the customer)".
--
-- The first-time-Assigned message (supabase_online_order_assigned_message.sql / _no_eta.sql) only goes
-- through Pancake's conversation API. A GMA-originated order has no Pancake conversation (Page_ID/
-- Conversation_ID are empty - see supabase_online_order_send_message.sql's header), so it always failed
-- with "missing Page_ID/Conversation_ID". Those customers are only reachable through the GMA Facebook
-- Page's own Send API, whose page token lives in Edge Function secrets, not the database - so for a GMA
-- order, admin_sync_online_order_assigned_status now returns the customer's psid + the message text
-- instead of sending, and js/onlineOrders.js sends it through chatbot-staff-reply (the same path as the
-- page's "Send Message" button, so it also shows up in the GMA Conversations thread), then logs the
-- outcome with admin_record_online_order_assigned_message below.
--
-- Facebook's 24h rule still applies: if the customer hasn't messaged the GMA Page in the last 24 hours,
-- the send fails (HUMAN_AGENT isn't approved yet) and staff get chatbot-staff-reply's plain-language
-- error in the alert.
--
-- Run AFTER supabase_online_order_assigned_message.sql and supabase_online_order_assigned_message_no_eta.sql;
-- if either is ever re-run, run this one again after it. Functions only - no table locks.

-- ---------------------------------------------------------------------------
-- 1. Message text on its own, so the Pancake and GMA routes send the exact same words. Same text as
--    _no_eta.sql's version.
create or replace function public._online_order_assigned_message_text(p_order_id text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_customer_name text;
  v_items_text text;
begin
  select "CustomerName" into v_customer_name from public."OnlineOrders" where "OrderID" = p_order_id;

  select string_agg(
    '✅ ' || trim(to_char(coalesce(l."Quantity", 1), 'FM999999990.##')) || ' x ' || coalesce(nullif(trim(l."Description"), ''), l."ItemCode")
      || case when nullif(trim(coalesce(l."Note", '')), '') is null then '' else ' 🧾 Note : ' || l."Note" end,
    chr(10) order by l."LineID"
  ) into v_items_text
  from public."OnlineOrderLines" l
  where l."OrderID" = p_order_id;

  -- ---- Message text: edit here ----
  return
    '🎉 Hi ' || coalesce(nullif(trim(v_customer_name), ''), 'there') || '! Good news - your order ' || p_order_id
    || ' is now in production. Our team has been assigned and has started building your items.' || chr(10) || chr(10)
    || '🧾 Here''s what we''re making:' || chr(10) || chr(10)
    || coalesce(v_items_text, '') || chr(10) || chr(10)
    || 'We''ll message you again once your order is ready. For any urgent matters, call +63 997 189 1662 or drop us a message here.'
    || chr(10) || chr(10)
    || 'Happy fish keeping 🐟 😊';
  -- ---------------------------------
end;
$$;

revoke execute on function public._online_order_assigned_message_text(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Pancake send - unchanged behaviour, now using the shared text above.
create or replace function public._send_online_order_assigned_message(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."OnlineOrders"%rowtype;
  v_response extensions.http_response;
begin
  select * into v_order from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found or v_order."Page_ID" is null or v_order."Conversation_ID" is null
     or trim(v_order."Page_ID") = '' or trim(v_order."Conversation_ID") = '' then
    raise exception 'Order is missing Page_ID/Conversation_ID - cannot message this customer.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  select * into v_response from extensions.http((
    'POST',
    'https://pages.fm/api/public_api/v1/pages/' || v_order."Page_ID" || '/conversations/' || v_order."Conversation_ID"
      || '/messages?page_access_token=' || public._pancake_public_api_key(),
    array[extensions.http_header('Accept', 'application/json'), extensions.http_header('Expect', '')],
    'application/json',
    -- json_build_object (not jsonb) keeps this key order - see _send_online_order_status_message.
    json_build_object('action', 'reply_inbox', 'message', public._online_order_assigned_message_text(p_order_id))::text
  )::extensions.http_request);

  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake messaging API returned HTTP %.', v_response.status;
  end if;
end;
$$;

revoke execute on function public._send_online_order_assigned_message(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Same as supabase_online_order_assigned_message.sql's version, plus gma_psid/gma_message: for a GMA
--    order's first Assigned, nothing is sent here - the client sends it via chatbot-staff-reply.
drop function if exists public.admin_sync_online_order_assigned_status(text, text, text);

create or replace function public.admin_sync_online_order_assigned_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(new_status text, changed boolean, estimated_delivery_date date, message_sent boolean, message_error text,
              gma_psid text, gma_message text)
language plpgsql
security definer
set search_path = public, extensions
set statement_timeout = '60000'
as $$
declare
  v_status text;
  v_status_key text;
  v_pre_status text;
  v_eta date;
  v_new_eta date;
  v_complete boolean;
  v_target text;
  v_thickness text;
  v_lead_days int;
  v_payload jsonb;
  v_message_sent boolean := false;
  v_message_error text;
  v_gma_psid text;
  v_gma_message text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (
    select 1 from public."StaffUsers"
    where "Username" = p_admin_username and "IsActive"
      and ("SuperUser" or 'ProductionManager' = any("StaffRoles"))
  ) then
    raise exception 'Only a Production Manager can assign orders.';
  end if;

  select "Status", "PreAssignStatus", "EstimatedDeliveryDate" into v_status, v_pre_status, v_eta
  from public."OnlineOrders" where "OrderID" = p_order_id;
  if not found then
    raise exception 'Order % not found.', p_order_id;
  end if;

  v_status_key := lower(trim(coalesce(v_status, '')));
  v_complete := public._online_order_assignment_complete(p_order_id);
  v_target := case
    when v_status_key in ('confirmed', 'submitted', 'printed') and v_complete then 'Assigned'
    when v_status_key = 'assigned' and not v_complete then coalesce(nullif(trim(v_pre_status), ''), 'Confirmed')
    else null
  end;

  if v_target is null then
    return query select v_status, false, v_eta, false, null::text, null::text, null::text;
    return;
  end if;

  if v_target = 'Assigned' then
    v_payload := jsonb_build_object('status', public._online_order_assigned_pancake_code());

    -- Same rule as the POS print step: only when the order has no date yet.
    if v_eta is null then
      select t.thickness into v_thickness
      from (values ('12mm', 1), ('10mm', 2), ('6mm', 3), ('3mm', 4)) as t(thickness, priority)
      where exists (
        select 1 from public."OnlineOrderLines" ol
        where ol."OrderID" = p_order_id
          and regexp_replace(coalesce(ol."Description", '') || coalesce(ol."Note", '') || coalesce(ol."ItemCode", ''), '[[:space:]]+', '', 'g') ilike '%' || t.thickness || '%'
      )
      order by t.priority
      limit 1;

      if v_thickness is not null then
        select max(m[1]::int) into v_lead_days
        from public."GlassPricingSetup" g,
             regexp_matches(coalesce(g."TurnAroundDays", ''), '([0-9]+)', 'g') as m
        where regexp_replace(upper(coalesce(g."Thickness", '')), '[[:space:]]+', '', 'g')
              in (upper(v_thickness), regexp_replace(v_thickness, '[^0-9]', '', 'g'));

        if coalesce(v_lead_days, 0) > 0 then
          v_new_eta := (now() at time zone 'Asia/Manila')::date + v_lead_days;
          -- Midnight Manila as UTC, same format as the POS's FormatEstimatedDeliveryDateForEndpoint.
          v_payload := v_payload || jsonb_build_object('estimate_delivery_date',
            to_char((v_new_eta::timestamp at time zone 'Asia/Manila') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
        end if;
      end if;
    end if;
  else
    v_payload := jsonb_build_object('status', case lower(v_target) when 'printed' then '13' else 'submitted' end);
  end if;

  perform public._pancake_patch_online_order_status(p_order_id, v_payload);

  update public."OnlineOrders"
  set "Status" = v_target,
      "PreAssignStatus" = case when v_target = 'Assigned' then v_status else null end,
      "EstimatedDeliveryDate" = coalesce(v_new_eta, "EstimatedDeliveryDate")
  where "OrderID" = p_order_id;

  -- First time Assigned: tell the customer it's in production (once per order, best-effort).
  if v_target = 'Assigned' and not exists (
    select 1 from public."OnlineOrderAssignedMessages" m where m."OrderID" = p_order_id and m."Sent"
  ) then
    -- Same GMA detection as admin_get_online_order_messaging_route (supabase_online_order_send_message.sql).
    select ao."GmaPsid" into v_gma_psid
    from public."AutomatedOrders" ao
    where ao."PancakeReceiptNo" = p_order_id
      and ao."GmaPsid" is not null
    limit 1;

    if v_gma_psid is not null then
      -- GMA Page order: the client sends it and logs the result (admin_record_online_order_assigned_message).
      v_gma_message := public._online_order_assigned_message_text(p_order_id);
    else
      begin
        perform public._send_online_order_assigned_message(p_order_id);
        v_message_sent := true;
      exception when others then
        v_message_error := sqlerrm;
      end;
      insert into public."OnlineOrderAssignedMessages" ("OrderID", "SentBy", "Sent", "Error")
      values (p_order_id, p_admin_username, v_message_sent, v_message_error)
      on conflict ("OrderID") do update
        set "SentAtUtc" = now(), "SentBy" = excluded."SentBy", "Sent" = excluded."Sent", "Error" = excluded."Error";
    end if;
  end if;

  return query select v_target, true, coalesce(v_new_eta, v_eta), v_message_sent, v_message_error, v_gma_psid, v_gma_message;
end;
$$;

grant execute on function public.admin_sync_online_order_assigned_status(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. Logs how the client-side GMA send went, so a sent message isn't repeated on re-assign (same
--    once-per-order rule as the Pancake route).
create or replace function public.admin_record_online_order_assigned_message(
  p_admin_username text,
  p_admin_password text,
  p_order_id text,
  p_sent boolean,
  p_error text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  insert into public."OnlineOrderAssignedMessages" ("OrderID", "SentBy", "Sent", "Error")
  values (p_order_id, p_admin_username, coalesce(p_sent, false), p_error)
  on conflict ("OrderID") do update
    set "SentAtUtc" = now(), "SentBy" = excluded."SentBy", "Sent" = excluded."Sent", "Error" = excluded."Error";
end;
$$;

grant execute on function public.admin_record_online_order_assigned_message(text, text, text, boolean, text) to anon;
