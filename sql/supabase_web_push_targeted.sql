-- Targeted Web Push - per "only sales user can have this please / also for makers can you do
-- different notifications?". Before this, every push went to every subscribed device.
--
-- - _trigger_web_push gains p_usernames (text[]): when set, the send-web-push Edge Function only
--   sends to devices whose PushSubscriptions."CreatedBy" is in that list. Null = every device
--   (still used by admin_test_web_push).
-- - "New confirmed order" now goes to active Sales Users only (StaffUsers."SalesUser"). Telegram
--   is unchanged (still the one shared chat).
-- - Makers get their own pushes, sent only to that maker's devices:
--     * Online order: when someone is set as AssignedTankMaker / AssignedStandMaker
--       ("New tank job assigned" / "New stand job assigned").
--     * Production order: when it's Released to its Tank/Stand Maker, or a maker is changed on an
--       already-Released order ("Production order released to you").
-- - staff_save_push_subscription now re-points a device to whoever enabled it last (CreatedBy was
--   kept from the first save before), so a shared phone follows the person who's logged in.
--
-- Run this AFTER supabase_web_push_subscriptions.sql, supabase_web_push_order_confirmed_trigger.sql,
-- supabase_online_order_maker_by_role.sql and supabase_production_orders.sql.
-- Also redeploy the Edge Function: supabase functions deploy send-web-push --project-ref hymcmesqgpliyyeghpgq

-- ---------------------------------------------------------------------------
-- 1. Device ownership follows the latest user who enabled notifications on it.

create or replace function public.staff_save_push_subscription(
  p_admin_username text,
  p_admin_password text,
  p_endpoint text,
  p_p256dh text,
  p_auth text
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

  if p_endpoint is null or trim(p_endpoint) = '' or p_p256dh is null or p_auth is null then
    raise exception 'endpoint, p256dh, and auth are all required.';
  end if;

  insert into public."PushSubscriptions" ("Endpoint", "P256dh", "Auth", "CreatedBy", "CreatedAtUtc", "LastSeenAtUtc")
  values (p_endpoint, p_p256dh, p_auth, p_admin_username, now(), now())
  on conflict ("Endpoint") do update
    set "P256dh" = excluded."P256dh",
        "Auth" = excluded."Auth",
        "CreatedBy" = excluded."CreatedBy",
        "LastSeenAtUtc" = now();
end;
$$;

grant execute on function public.staff_save_push_subscription(text, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. _trigger_web_push with an optional recipient list.

drop function if exists public._trigger_web_push(text, text, text);
drop function if exists public._trigger_web_push(text, text, text, text[]);

create or replace function public._trigger_web_push(
  p_title text,
  p_body text,
  p_url text default 'dashboard.html',
  p_usernames text[] default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  -- Public/"publishable" anon key - same value already committed in docs/js/config.js.
  v_anon_key text := 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz';
  v_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/send-web-push';
  v_payload jsonb;
begin
  -- A targeted push with nobody to target is a no-op, not a broadcast.
  if p_usernames is not null and coalesce(array_length(p_usernames, 1), 0) = 0 then
    return;
  end if;

  -- Skip the HTTP call when none of the recipients has a subscribed device.
  if not exists (
    select 1 from public."PushSubscriptions"
    where p_usernames is null or "CreatedBy" = any(p_usernames)
  ) then
    return;
  end if;

  v_payload := jsonb_build_object('title', p_title, 'body', p_body, 'url', p_url);
  if p_usernames is not null then
    v_payload := v_payload || jsonb_build_object('usernames', to_jsonb(p_usernames));
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
    perform extensions.http((
      'POST',
      v_url,
      array[
        extensions.http_header('Authorization', 'Bearer ' || v_anon_key),
        extensions.http_header('apikey', v_anon_key)
      ],
      'application/json',
      v_payload::text
    )::extensions.http_request);
  exception when others then
    -- Never let a push failure break the order/production transaction that triggered it.
    null;
  end;
end;
$$;

revoke all on function public._trigger_web_push(text, text, text, text[]) from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Confirmed order -> Sales Users only (Telegram unchanged).

create or replace function public._notify_order_confirmed_channels()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_was_confirmed boolean := false;
  v_is_confirmed boolean;
  v_title text;
  v_body text;
  v_sales_users text[];
begin
  v_is_confirmed := lower(trim(coalesce(NEW."Status", ''))) in ('confirmed', 'submitted');

  if TG_OP = 'UPDATE' then
    v_was_confirmed := lower(trim(coalesce(OLD."Status", ''))) in ('confirmed', 'submitted');
  end if;

  if v_is_confirmed and not v_was_confirmed and NEW."ReceivedAtShop" is not true then
    v_title := 'New confirmed order';
    v_body := 'Order ' || coalesce(NEW."OrderID", '-')
      || ' - ' || coalesce(NEW."CustomerName", '-')
      || ' - PHP ' || to_char(coalesce(NEW."MoneyToCollect", 0), 'FM999,999,990.00')
      || ' - Confirmed by ' || coalesce(NEW."ConfirmedBy", '-');

    perform public._telegram_send_message(v_title || E'\n' || v_body);

    select coalesce(array_agg("Username"::text), '{}') into v_sales_users
    from public."StaffUsers"
    where "IsActive" and "SalesUser";

    perform public._trigger_web_push(v_title, v_body, 'dashboard.html', v_sales_users);
  end if;

  return NEW;
end;
$$;

-- (trigger trg_notify_order_confirmed_channels already points at this function - unchanged)

-- ---------------------------------------------------------------------------
-- 4. Online order maker assignment -> that maker only. UPDATE only, and only when the assignee
--    actually changes, so Pancake re-syncs of the same row don't re-notify.

create or replace function public._notify_online_order_maker_assigned()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_order text := 'Order ' || coalesce(NEW."OrderID", '-') || ' - ' || coalesce(NEW."CustomerName", '-');
begin
  if NEW."AssignedTankMaker" is not null and NEW."AssignedTankMaker" is distinct from OLD."AssignedTankMaker" then
    perform public._trigger_web_push('New tank job assigned', v_order, 'online-orders.html', array[NEW."AssignedTankMaker"::text]);
  end if;

  if NEW."AssignedStandMaker" is not null and NEW."AssignedStandMaker" is distinct from OLD."AssignedStandMaker" then
    perform public._trigger_web_push('New stand job assigned', v_order, 'online-orders.html', array[NEW."AssignedStandMaker"::text]);
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_notify_online_order_maker_assigned on public."OnlineOrders";
create trigger trg_notify_online_order_maker_assigned
  after update of "AssignedTankMaker", "AssignedStandMaker" on public."OnlineOrders"
  for each row
  execute function public._notify_online_order_maker_assigned();

-- ---------------------------------------------------------------------------
-- 5. Production order released (or maker swapped while Released) -> that maker only.

create or replace function public._notify_production_order_released()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_just_released boolean := NEW."Status" = 'Released' and OLD."Status" is distinct from 'Released';
  v_body text := 'Production ' || NEW."No" || coalesce(' - ' || nullif(trim(NEW."Description"), ''), '')
    || coalesce(' - due ' || to_char(NEW."DueDate", 'Mon DD'), '');
begin
  if NEW."Status" <> 'Released' then
    return NEW;
  end if;

  if NEW."TankMaker" is not null and (v_just_released or NEW."TankMaker" is distinct from OLD."TankMaker") then
    perform public._trigger_web_push('Production order released to you', v_body, 'production-orders.html', array[NEW."TankMaker"::text]);
  end if;

  if NEW."StandMaker" is not null and NEW."StandMaker" is distinct from NEW."TankMaker"
     and (v_just_released or NEW."StandMaker" is distinct from OLD."StandMaker") then
    perform public._trigger_web_push('Production order released to you', v_body, 'production-orders.html', array[NEW."StandMaker"::text]);
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_notify_production_order_released on public."ProductionOrders";
create trigger trg_notify_production_order_released
  after update of "Status", "TankMaker", "StandMaker" on public."ProductionOrders"
  for each row
  execute function public._notify_production_order_released();
