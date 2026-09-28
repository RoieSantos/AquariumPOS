-- "In production" message when a custom order is first Assigned - per "once the confirmed orders has
-- been assigned can you populate the estimated delivery date also did you see how we send over the
-- message after printed? i want to send a different set of message once assigned".
--
-- The POS sends "Your order ... is printed the processing of your items will start very soon..." on
-- an order's FIRST print (OnlineOrdersForm.cs NotifyCustomerOrderPrintedAsync). Custom orders now skip
-- printing and are Assigned on the portal instead (supabase_online_order_assigned_status.sql), so they
-- were getting no message at all. This sends its own message the first time an order becomes
-- Assigned: it's in production, the estimated delivery date assigning sets, and the items. Sent once
-- per order (logged in OnlineOrderAssignedMessages), so reassigning or un-assigning then re-assigning
-- doesn't message the customer again. Best-effort: a failed send never undoes the status change, and
-- the portal shows the error.
--
-- Estimated delivery date: already set by admin_sync_online_order_assigned_status (today + the
-- turnaround days of the order's thickest glass, only if the order has no date yet), unchanged here.
-- It only works once GlassPricingSetup."TurnAroundDays" is filled - step 3 at the bottom checks that.
--
-- Re-creates admin_sync_online_order_assigned_status (return columns change). Run AFTER
-- supabase_online_order_assigned_status.sql; if that file is ever re-run, run this one again after it.
-- New table only - no OnlineOrders lock.

create table if not exists public."OnlineOrderAssignedMessages" (
  "OrderID" text primary key,
  "SentAtUtc" timestamptz not null default now(),
  "SentBy" text,
  "Sent" boolean not null,
  "Error" text
);

alter table public."OnlineOrderAssignedMessages" enable row level security;
revoke all on public."OnlineOrderAssignedMessages" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Builds and sends the message (raises on failure). Same Pancake public messaging endpoint and
-- payload as _send_online_order_status_message (supabase_online_order_portal_status_update.sql).
drop function if exists public._send_online_order_assigned_message(text);

create or replace function public._send_online_order_assigned_message(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order public."OnlineOrders"%rowtype;
  v_items_text text;
  v_eta_text text := '';
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

  if v_order."EstimatedDeliveryDate" is not null then
    v_eta_text := chr(10) || '📅 Estimated completion: ' || to_char(v_order."EstimatedDeliveryDate", 'FMMonth FMDD, YYYY') || chr(10);
  end if;

  -- ---- Message text: edit here ----
  v_message :=
    '🎉 Hi ' || coalesce(nullif(trim(v_order."CustomerName"), ''), 'there') || '! Good news - your order ' || p_order_id
    || ' is now in production. Our team has been assigned and has started building your items.' || chr(10)
    || v_eta_text || chr(10)
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

-- ---------------------------------------------------------------------------
-- Same as supabase_online_order_assigned_status.sql's version, plus: the first time an order becomes
-- Assigned, send the "in production" message (message_sent / message_error say how it went).
drop function if exists public.admin_sync_online_order_assigned_status(text, text, text);

create or replace function public.admin_sync_online_order_assigned_status(
  p_admin_username text,
  p_admin_password text,
  p_order_id text
)
returns table(new_status text, changed boolean, estimated_delivery_date date, message_sent boolean, message_error text)
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
    return query select v_status, false, v_eta, false, null::text;
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

  return query select v_target, true, coalesce(v_new_eta, v_eta), v_message_sent, v_message_error;
end;
$$;

grant execute on function public.admin_sync_online_order_assigned_status(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 3. CHECK (run on its own): the glass turnaround days the Estimated Delivery Date is built from.
--    A blank TurnAroundDays means assigning an order with that glass sets no date.
-- select "Uom", "Thickness", "TurnAroundDays" from public."GlassPricingSetup" order by "Thickness";
