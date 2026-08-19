-- Extends the order-confirmed notification trigger (originally Telegram-only, see
-- supabase_telegram_notifications.sql) to ALSO push straight to the Portal PWA via Web Push, so
-- the notification can come from the portal itself instead of a third-party app. Run this AFTER
-- supabase_telegram_notifications.sql and supabase_web_push_subscriptions.sql.
--
-- Web Push messages must be individually encrypted per-subscriber (RFC 8291) and signed with a
-- VAPID JWT (RFC 8292) - real crypto that plain Postgres/plpgsql has no reasonable way to do, so
-- this calls out to the send-web-push Edge Function (supabase/functions/send-web-push) instead of
-- doing the send here directly, the same way Lalamove's HMAC-signed API calls are proxied through
-- an Edge Function rather than attempted from SQL. The Edge Function itself reads every row in
-- PushSubscriptions and fans the same message out to all of them - any number of staff devices,
-- no per-device wiring needed here.
--
-- The call uses the public anon key (same one already exposed in docs/js/config.js - it's the
-- "publishable" key by design, not a secret) just to satisfy the Edge Function's default JWT
-- verification; the function itself does its own privileged DB read using its OWN
-- auto-injected SUPABASE_SERVICE_ROLE_KEY, not anything passed in from here.
drop function if exists public._trigger_web_push(text, text, text);

create or replace function public._trigger_web_push(p_title text, p_body text, p_url text default 'dashboard.html')
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  -- Public/"publishable" anon key - safe to inline, same value already committed in
  -- docs/js/config.js (window.APP_CONFIG.SUPABASE_ANON_KEY).
  v_anon_key text := 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz';
  v_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/send-web-push';
begin
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
      jsonb_build_object('title', p_title, 'body', p_body, 'url', p_url)::text
    )::extensions.http_request);
  exception when others then
    -- Never let a push failure (Edge Function not deployed yet, network hiccup, etc.) break the
    -- order sync transaction that triggered this - same guarantee _telegram_send_message makes.
    null;
  end;
end;
$$;

revoke all on function public._trigger_web_push(text, text, text) from anon, authenticated;

-- Test/debug entry point - unlike _trigger_web_push above (which swallows every failure so it can
-- never break the order sync transaction), this calls the Edge Function directly and surfaces
-- exactly what came back (HTTP status + body), same "don't hide the error while setting things
-- up" precedent as admin_test_telegram_notification (supabase_telegram_notifications.sql).
drop function if exists public.admin_test_web_push(text, text, text);

create or replace function public.admin_test_web_push(
  p_admin_username text,
  p_admin_password text,
  p_text text default 'Test notification from RS Pet Stop Portal.'
)
returns table(ok boolean, http_status int, response_body text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_anon_key text := 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz';
  v_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/send-web-push';
  v_response extensions.http_response;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (select 1 from public."PushSubscriptions") then
    return query select false, null::int, 'No devices are subscribed yet - tap "Enable Order Notifications" on the Dashboard from the phone/browser you want to test first.'::text;
    return;
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  select * into v_response from extensions.http((
    'POST',
    v_url,
    array[
      extensions.http_header('Authorization', 'Bearer ' || v_anon_key),
      extensions.http_header('apikey', v_anon_key)
    ],
    'application/json',
    jsonb_build_object('title', 'Test Notification', 'body', p_text, 'url', 'dashboard.html')::text
  )::extensions.http_request);

  return query select (v_response.status >= 200 and v_response.status < 300), v_response.status, left(v_response.content, 500);
end;
$$;

grant execute on function public.admin_test_web_push(text, text, text) to anon;

-- Replaces supabase_telegram_notifications.sql's trigger function with one that fans the same
-- "order just got confirmed" event out to both channels - Telegram (if TELEGRAM_BOT_TOKEN/
-- TELEGRAM_CHAT_ID are set) and Web Push (if any device has subscribed). Both are independently
-- optional and independently safe to fail - having only one, both, or neither configured all work
-- fine. Trigger condition (fires once per order, on the actual transition into Confirmed/
-- Submitted, online orders only) is unchanged from the original.
drop trigger if exists trg_notify_telegram_on_order_confirmed on public."OnlineOrders";
drop function if exists public._notify_telegram_on_order_confirmed();

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
    perform public._trigger_web_push(v_title, v_body);
  end if;

  return NEW;
end;
$$;

create trigger trg_notify_order_confirmed_channels
  after insert or update on public."OnlineOrders"
  for each row
  execute function public._notify_order_confirmed_channels();
