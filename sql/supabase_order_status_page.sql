-- Customer order status page (docs/order-status.html) - per "create a status update for the customers always
-- asking for update ... when the customer ask for update or status we just send the link and they will see
-- what is happening to their order". Informative only: nothing on the page changes the order.
--
-- The link is https://rspetstop.com/order-status.html?t=<token>. The token is random, NOT the order number:
-- order numbers count up (AO-00012, AO-00013...), so ?order=AO-00012 would let anyone read the next
-- customer's order (same reason the bot checks the order belongs to the chat - chatbot-engine.ts
-- "Order privacy"). One token per order, so sending the link again gives the same link.
--
-- Covers:
--   kind 'online'  - an Online Order (OrderID: AO-xxxxx, WI-xxxxx walk-ins, old Pancake numbers), or an
--                    AO-xxxxx order still waiting for staff to confirm it (AutomatedOrders only).
--   kind 'advance' - an Advance Order (AdvanceOrders."TransactionNo").
--
-- What the customer sees: a progress timeline, how each part of the build is going (no maker names), the
-- delivery date when it's on the delivery calendar, total / paid / balance (+ the Pay Online link when online
-- payment is open for the order), the photos staff sent with "Send Photo", and the items. Only the first
-- name - no address, phone or staff names.
--
--   staff_get_order_status_link(user, password/session token, kind, order_ref) -> token   (any active staff)
--   _order_status_link(kind, order_ref)                                         -> token   (service_role: Alice)
--   public_get_order_status_page(token)                                         -> jsonb   (anon: the page)
--
-- Run AFTER supabase_chatbot_walkin_order_status.sql, supabase_chatbot_order_payment_status.sql,
-- supabase_online_order_for_delivery_status.sql and supabase_advance_order_void.sql.
-- Safe to re-run. Ends with ONE result (the newest orders' links, to try the page).

create extension if not exists pgcrypto with schema extensions;

-- ============================================================================
-- 1. Links
-- ============================================================================
create table if not exists public."OrderStatusLinks" (
  "Token" varchar(40) primary key,
  "Kind" varchar(20) not null check ("Kind" in ('online', 'advance')),
  "OrderRef" varchar(100) not null,
  "CreatedBy" varchar(100),
  "CreatedAtUtc" timestamptz not null default now(),
  "LastViewedAtUtc" timestamptz,
  "ViewCount" int not null default 0,
  unique ("Kind", "OrderRef")
);

alter table public."OrderStatusLinks" enable row level security;
revoke all on public."OrderStatusLinks" from anon, authenticated;

-- The order's link, created the first time it's asked for. null when there's no such order.
create or replace function public._order_status_link(p_kind text, p_order_ref text, p_created_by text default null)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_kind text := lower(trim(coalesce(p_kind, '')));
  v_ref text := trim(coalesce(p_order_ref, ''));
  v_token text;
begin
  if v_ref = '' or v_kind not in ('online', 'advance') then
    return null;
  end if;

  if v_kind = 'online' then
    -- A confirmed AO keeps its AO- number as OrderID; an old one pushed to Pancake has PancakeReceiptNo.
    select coalesce(
             (select o."OrderID"::text from public."OnlineOrders" o where o."OrderID" = v_ref),
             (select coalesce(nullif(trim(a."PancakeReceiptNo"), ''), a."OrderNo")::text
                from public."AutomatedOrders" a where upper(a."OrderNo") = upper(v_ref)))
      into v_ref;
    if v_ref is null then
      return null;
    end if;
  elsif not exists (select 1 from public."AdvanceOrders" a where a."TransactionNo" = v_ref) then
    return null;
  end if;

  select l."Token" into v_token from public."OrderStatusLinks" l where l."Kind" = v_kind and l."OrderRef" = v_ref;
  if v_token is not null then
    return v_token;
  end if;

  -- 16 url-safe characters (96 random bits).
  v_token := translate(encode(extensions.gen_random_bytes(12), 'base64'), '+/', '-_');
  insert into public."OrderStatusLinks" ("Token", "Kind", "OrderRef", "CreatedBy")
  values (v_token, v_kind, v_ref, p_created_by)
  on conflict ("Kind", "OrderRef") do nothing;

  select l."Token" into v_token from public."OrderStatusLinks" l where l."Kind" = v_kind and l."OrderRef" = v_ref;
  return v_token;
end;
$$;

revoke all on function public._order_status_link(text, text, text) from public, anon, authenticated;
grant execute on function public._order_status_link(text, text, text) to service_role;

create or replace function public.staff_get_order_status_link(
  p_admin_username text, p_admin_password text, p_kind text, p_order_ref text
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  v_token := public._order_status_link(p_kind, p_order_ref, p_admin_username);
  if v_token is null then
    raise exception 'Order % not found.', p_order_ref;
  end if;
  return v_token;
end;
$$;

grant execute on function public.staff_get_order_status_link(text, text, text, text) to anon;

-- ============================================================================
-- 2. The page's data
-- ============================================================================
-- steps: [{key, label, at, note, state}] - state 'done' / 'current' (where the order is now) / 'upcoming'.
-- The page draws them in order; v_stage is the index of the current step (1-based).
create or replace function public.public_get_order_status_page(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_link public."OrderStatusLinks"%rowtype;
  v_oo public."OnlineOrders"%rowtype;
  v_has_oo boolean := false;
  v_ao public."AutomatedOrders"%rowtype;
  v_has_ao boolean := false;
  v_adv public."AdvanceOrders"%rowtype;
  v_prod public."AdvanceOrderProduction"%rowtype;
  v_status text;
  v_walkin_stage text;
  v_is_walkin boolean := false;
  v_cancelled boolean := false;
  v_steps jsonb := '[]'::jsonb;
  v_stage int := 1;
  v_parts jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
  v_photos jsonb := '[]'::jsonb;
  v_payment jsonb;
  v_pay jsonb;
  v_delivery_date date;
  v_delivery_done boolean := false;
  v_has_build boolean := false;
  v_build_done boolean := false;
  v_needs_tank boolean;
  v_needs_stand boolean;
  v_order_no text;
  v_receipt_no text;
  v_order_date date;
  v_branch text;
  v_customer text;
  v_type text;
  v_target date;
  v_final_label text := 'Delivered';
  v_final_at timestamptz;
  v_ready_note text;
  v_today date := (now() at time zone 'Asia/Manila')::date;
begin
  select * into v_link from public."OrderStatusLinks" where "Token" = trim(coalesce(p_token, ''));
  if not found then
    return null;
  end if;

  update public."OrderStatusLinks"
     set "LastViewedAtUtc" = now(), "ViewCount" = "ViewCount" + 1
   where "Token" = v_link."Token";

  -- ------------------------------------------------------------------------
  -- Online / walk-in / not-yet-confirmed AO
  -- ------------------------------------------------------------------------
  if v_link."Kind" = 'online' then
    select * into v_oo from public."OnlineOrders" where "OrderID" = v_link."OrderRef";
    v_has_oo := found;
    select * into v_ao from public."AutomatedOrders"
     where upper("OrderNo") = upper(v_link."OrderRef") or "PancakeReceiptNo" = v_link."OrderRef"
     order by "CreatedAtUtc" desc limit 1;
    v_has_ao := found;
    if not v_has_oo and not v_has_ao then
      return null;
    end if;

    v_order_no := v_link."OrderRef";
    v_customer := split_part(trim(coalesce(
                    case when v_has_oo and v_oo."ReceivedAtShop" is true then nullif(trim(v_oo."WalkinCustomerName"), '') end,
                    nullif(trim(v_ao."CustomerName"), ''), v_oo."CustomerName", '')), ' ', 1);

    -- Payment: same figures the bot and the pay page use (test payments left out).
    v_pay := public._chatbot_order_payment_status(v_order_no);
    if v_pay is not null then
      v_payment := jsonb_build_object(
        'total', v_pay->'total', 'paid', v_pay->'amount_paid', 'balance', v_pay->'balance',
        'pay_url', case when coalesce((v_pay->>'pay_link_ok')::boolean, false)
                        then 'https://www.rspetstop.com/pay.html?order=' || (v_pay->>'order_ref') end);
    end if;

    if not v_has_oo then
      -- Still waiting for staff to confirm it (AutomatedOrders only).
      v_type := 'Online Order';
      v_order_date := (v_ao."CreatedAtUtc" at time zone 'Asia/Manila')::date;
      v_cancelled := lower(trim(coalesce(v_ao."Status", ''))) in ('cancelled', 'canceled', 'cancel');
      select coalesce(jsonb_agg(jsonb_build_object('name', l."ItemName", 'qty', l."Quantity") order by l."EntryNo"), '[]'::jsonb)
        into v_items from public."AutomatedOrderLines" l where l."OrderNo" = v_ao."OrderNo";
      v_steps := jsonb_build_array(
        jsonb_build_object('key', 'received', 'label', 'Order received', 'at', v_ao."CreatedAtUtc",
                           'note', 'Our team is reviewing your order and will confirm it shortly.'),
        jsonb_build_object('key', 'confirmed', 'label', 'Order confirmed'),
        jsonb_build_object('key', 'ready', 'label', 'Ready'),
        jsonb_build_object('key', 'shipped', 'label', 'Shipped'),
        jsonb_build_object('key', 'delivered', 'label', 'Delivered'));
      v_stage := 1;
    else
      v_status := lower(trim(coalesce(v_oo."Status", '')));
      v_is_walkin := v_oo."ReceivedAtShop" is true;
      v_type := case when v_is_walkin then 'Walk-in Order' else 'Online Order' end;
      v_order_date := v_oo."Date"::date;
      v_cancelled := v_status in ('canceled', 'cancelled');
      select coalesce(w."Name"::text, v_oo."LocationID"::text) into v_branch
        from (select 1) x left join public."Warehouses" w on w."ID" = v_oo."LocationID";
      select coalesce(jsonb_agg(jsonb_build_object('name', l.item_name, 'qty', l.quantity)), '[]'::jsonb)
        into v_items from public.public_get_online_order_lines(v_oo."OrderID") l;

      -- Per-part build progress (no names) - one row per part.
      select coalesce(jsonb_agg(jsonb_build_object(
               'part', case p.part when 'tank' then 'Aquarium' when 'stand' then 'Stand / cover'
                                   when 'dispatcher' then 'Order preparation' else initcap(p.part) end,
               'state', case when p.done or (p.qty is not null and p.qty_built >= p.qty) then 'done'
                             when p.assigned and coalesce(p.build_status, '') <> 'Open' then 'building'
                             else 'waiting' end,
               'done_at', p.done_at,
               'qty', p.qty, 'qty_built', p.qty_built)), '[]'::jsonb)
        into v_parts
        from public.public_get_online_order_production(v_oo."OrderID") p;
      v_has_build := jsonb_array_length(v_parts) > 0;
      v_build_done := v_has_build and not exists (select 1 from jsonb_array_elements(v_parts) e where e->>'state' <> 'done');

      select coalesce(jsonb_agg(jsonb_build_object('url', ph."PublicUrl", 'at', ph."UploadedAtUtc", 'status', ph."Status")
                                order by ph."UploadedAtUtc" desc), '[]'::jsonb)
        into v_photos
        from (select * from public."OnlineOrderStatusPhotos" x
               where x."OrderID" = v_oo."OrderID" and x."SendError" is null
               order by x."UploadedAtUtc" desc limit 12) ph;

      if v_is_walkin then
        v_walkin_stage := public._walkin_order_stage(v_oo."OrderID");
        v_target := v_oo."WalkinDueDate";
        v_payment := null; -- paid at the counter, they hold the POS receipt (the bot leaves payment out too)
        v_steps := jsonb_build_array(
          jsonb_build_object('key', 'received', 'label', 'Order received', 'at', v_oo."Date"::date,
                             'note', case when v_walkin_stage = 'To Assign' then 'Waiting for our production team to start on it.' end),
          jsonb_build_object('key', 'building', 'label', 'Being built'),
          jsonb_build_object('key', 'ready', 'label', 'Ready for pickup',
                             'note', 'At our ' || coalesce(v_branch, '') || ' branch.'),
          jsonb_build_object('key', 'picked_up', 'label', 'Picked up', 'at', v_oo."PickedUpAtUtc"));
        v_stage := case v_walkin_stage when 'To Assign' then 1 when 'Assigned' then 2 when 'Production Done' then 3
                                       else 4 end;
      else
        -- Delivery calendar: the next open stop (not Marked Done), else the last one.
        select s."DeliveryDate",
               exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID")
          into v_delivery_date, v_delivery_done
          from public."DeliveryStops" s
         where s."OrderID" = v_oo."OrderID"
         order by exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID"),
                  s."DeliveryDate" desc
         limit 1;

        v_final_label := case when v_oo."PickedUpAtUtc" is not null then 'Picked up' else 'Delivered' end;
        v_final_at := coalesce(v_oo."DeliveredAtUtc", v_oo."PickedUpAtUtc");
        v_ready_note := case when v_delivery_date is not null and not v_delivery_done
                             then 'Scheduled for delivery on ' || to_char(v_delivery_date, 'FMMon DD, YYYY') || '.' end;

        v_steps := jsonb_build_array(
          jsonb_build_object('key', 'received', 'label', 'Order received',
                             'at', coalesce(v_ao."CreatedAtUtc", v_oo."Date"::date::timestamptz)),
          jsonb_build_object('key', 'confirmed', 'label', 'Order confirmed', 'at', v_oo."ConfirmedAtUtc"));
        if v_has_build then
          v_steps := v_steps || jsonb_build_object('key', 'building', 'label', 'Being built');
        end if;
        v_steps := v_steps
          || jsonb_build_object('key', 'ready', 'label', 'Ready for delivery', 'note', v_ready_note)
          || jsonb_build_object('key', 'shipped', 'label', 'Shipped', 'note', 'On its way to you.')
          || jsonb_build_object('key', 'delivered', 'label', v_final_label, 'at', v_final_at);

        v_stage := case
          when v_final_at is not null or v_status = 'delivered' then 99
          when v_status in ('shipped', '2') then 98
          when v_status in ('to ship', 'packing', 'packed') or v_build_done then 97
          when v_has_build and (v_status in ('assigned', 'printed')
                                or exists (select 1 from jsonb_array_elements(v_parts) e where e->>'state' <> 'waiting')) then 3
          else 2
        end;
        -- 97/98/99 = ready / shipped / delivered, wherever they fall (the building step may be missing).
        v_stage := case v_stage when 99 then jsonb_array_length(v_steps)
                                when 98 then jsonb_array_length(v_steps) - 1
                                when 97 then jsonb_array_length(v_steps) - 2
                                else v_stage end;
      end if;
    end if;

  -- ------------------------------------------------------------------------
  -- Advance order
  -- ------------------------------------------------------------------------
  else
    select * into v_adv from public."AdvanceOrders" where "TransactionNo" = v_link."OrderRef";
    if not found then
      return null;
    end if;
    select * into v_prod from public."AdvanceOrderProduction" where "TransactionNo" = v_adv."TransactionNo";

    v_type := 'Advance Order';
    v_order_no := v_adv."TransactionNo";
    v_receipt_no := v_adv."ReceiptNo";
    v_order_date := v_adv."Date"::date;
    v_branch := v_adv."Warehouse";
    v_customer := split_part(trim(coalesce(v_adv."CustomerName", '')), ' ', 1);
    v_cancelled := coalesce(v_adv."IsVoid", false);
    v_status := public._advance_order_prod_status(v_prod);

    v_payment := jsonb_build_object(
      'total', v_adv."NetAmount",
      'paid', case when coalesce(v_adv."FullyPaid", false) or coalesce(v_adv."Balance", 0) <= 0
                   then v_adv."NetAmount" else greatest(coalesce(v_adv."NetAmount", 0) - coalesce(v_adv."Balance", 0), 0) end,
      'balance', case when coalesce(v_adv."FullyPaid", false) then 0 else greatest(coalesce(v_adv."Balance", 0), 0) end);

    select coalesce(jsonb_agg(jsonb_build_object('name', l."Description", 'qty', l."Quantity")
                              order by case when l."LineNo" ~ '^\d+$' then l."LineNo"::numeric end nulls last, l."LineNo"), '[]'::jsonb)
      into v_items
      from public."AdvanceOrderLines" l
     where l."TransactionNo" = v_adv."TransactionNo" and coalesce(l."Quantity", 0) <> 0
       and nullif(trim(coalesce(l."Description", '')), '') is not null;

    select n.needs_tank, n.needs_stand into v_needs_tank, v_needs_stand from public._advance_order_needs(v_adv."TransactionNo") n;
    if coalesce(v_needs_tank, false) or v_prod."TankMaker" is not null then
      v_parts := v_parts || jsonb_build_object('part', 'Aquarium',
        'state', case when v_prod."TankDoneAtUtc" is not null or v_prod."ToShipAtUtc" is not null then 'done'
                      when v_prod."TankMaker" is not null then 'building' else 'waiting' end,
        'done_at', v_prod."TankDoneAtUtc");
    end if;
    if coalesce(v_needs_stand, false) or v_prod."StandMaker" is not null then
      v_parts := v_parts || jsonb_build_object('part', 'Stand / cover',
        'state', case when v_prod."StandDoneAtUtc" is not null or v_prod."ToShipAtUtc" is not null then 'done'
                      when v_prod."StandMaker" is not null then 'building' else 'waiting' end,
        'done_at', v_prod."StandDoneAtUtc");
    end if;
    v_has_build := jsonb_array_length(v_parts) > 0;

    select s."DeliveryDate",
           exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID")
      into v_delivery_date, v_delivery_done
      from public."DeliveryStops" s
     where s."AdvanceTransactionNo" = v_adv."TransactionNo"
     order by exists (select 1 from public."DeliveryStopCompletions" c where c."StopID" = s."StopID"),
              s."DeliveryDate" desc
     limit 1;
    v_ready_note := case when v_delivery_date is not null and not v_delivery_done
                         then 'Scheduled for delivery on ' || to_char(v_delivery_date, 'FMMon DD, YYYY') || '.' end;

    v_steps := jsonb_build_array(
      jsonb_build_object('key', 'received', 'label', 'Order placed', 'at', v_adv."Date"::date,
                         'note', case when v_has_build and v_status is null then 'Waiting for our production team to start on it.' end));
    if v_has_build then
      v_steps := v_steps || jsonb_build_object('key', 'building', 'label', 'Being built', 'at', v_prod."AssignedAtUtc");
    end if;
    v_steps := v_steps
      || jsonb_build_object('key', 'ready', 'label', 'Ready', 'at', v_prod."ToShipAtUtc", 'note', v_ready_note)
      || jsonb_build_object('key', 'shipped', 'label', 'Shipped', 'at', v_prod."ShippedAtUtc", 'note', 'On its way to you.')
      || jsonb_build_object('key', 'delivered', 'label', 'Delivered', 'at', v_prod."DeliveredAtUtc");

    v_stage := case v_status
      when 'Delivered' then jsonb_array_length(v_steps)
      when 'Shipped' then jsonb_array_length(v_steps) - 1
      when 'To Ship' then jsonb_array_length(v_steps) - 2
      when 'Production Done' then jsonb_array_length(v_steps) - 2
      when 'Assigned' then 2
      else 1
    end;
  end if;

  -- Mark each step done / current / upcoming. A finished order (last step reached) is all done.
  select coalesce(jsonb_agg(
           s.step || jsonb_build_object('state',
             case when s.i < v_stage or v_stage >= jsonb_array_length(v_steps) then 'done'
                  when s.i = v_stage then 'current' else 'upcoming' end)
           order by s.i), '[]'::jsonb)
    into v_steps
    from jsonb_array_elements(v_steps) with ordinality s(step, i);

  return jsonb_build_object(
    'order_no', v_order_no,
    'receipt_no', v_receipt_no,
    'order_type', v_type,
    'order_date', v_order_date,
    'branch', v_branch,
    'customer_first_name', nullif(v_customer, ''),
    'cancelled', v_cancelled,
    'current_label', (select e->>'label' from jsonb_array_elements(v_steps) e where e->>'state' = 'current' limit 1),
    'completed', not v_cancelled and v_stage >= jsonb_array_length(v_steps),
    'steps', v_steps,
    'parts', v_parts,
    'delivery_date', case when v_delivery_date is not null and not v_delivery_done then v_delivery_date end,
    'delivery_is_today', v_delivery_date = v_today and not v_delivery_done,
    'target_ready_date', v_target,
    'payment', v_payment,
    'items', v_items,
    'photos', v_photos,
    'checked_at', now()
  );
end;
$$;

grant execute on function public.public_get_order_status_page(text) to anon;

notify pgrst, 'reload schema';

-- ============================================================================
-- Check: links for the 5 newest open online orders and 5 newest advance orders - open one to try the page
-- (creates their links if they don't have one yet, which is harmless).
-- ============================================================================
select 'online' as kind, o."OrderID" as order_ref, o."Status" as status,
       'https://rspetstop.com/order-status.html?t=' || public._order_status_link('online', o."OrderID", 'setup-check') as link
from (select * from public."OnlineOrders"
       where lower(coalesce("Status", '')) not in ('canceled', 'cancelled', 'delivered')
       order by "Date" desc nulls last limit 5) o
union all
select 'advance', a."TransactionNo", coalesce(public._advance_order_prod_status(p), 'New'),
       'https://rspetstop.com/order-status.html?t=' || public._order_status_link('advance', a."TransactionNo", 'setup-check')
from (select * from public."AdvanceOrders" where not coalesce("IsVoid", false)
       order by "Date" desc nulls last limit 5) a
left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo";
