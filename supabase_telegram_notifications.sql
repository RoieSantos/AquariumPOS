-- Per "in the portal can we trigger a notification that will notify our phone... if there is a
-- confirm order came in the phone will get notify" - sends a Telegram message the moment an
-- online order's Status transitions INTO Confirmed/Submitted (fires exactly once per order, the
-- first time it's seen confirmed - a row that's already confirmed and gets synced/updated again
-- later for other reasons does NOT re-notify).
--
-- SETUP (run once):
--   1. Message @BotFather on Telegram -> /newbot -> follow the prompts -> copy the bot token it
--      gives you (looks like 123456789:AAExampleTokenTextHere).
--   2. Start a chat with your new bot (search its username, tap Start) - or add it to a group.
--      Send it any message so it has something to look at.
--   3. In a browser, open: https://api.telegram.org/bot<YOUR TOKEN>/getUpdates
--      Find "chat":{"id": ...} in the response - that number (can be negative, for a group) is
--      your chat_id.
--   4. Run this file once in the Supabase SQL editor.
--   5. In the Web Portal: General Setup -> "Secure API Keys" -> paste the bot token -> Save to
--      Vault. Then in the Settings table further down that same page, add/edit a row with key
--      TELEGRAM_CHAT_ID and your chat id from step 3 as the value (already seeded blank below, so
--      it'll show up ready to edit - no SQL needed for this part).
--   6. Test it: select * from public.admin_test_telegram_notification('<username>', '<password>');
--      - returns ok/http_status/response_body so you can see exactly what happened if it fails.
--
-- Both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set for anything to actually send - until
-- then, _telegram_send_message silently no-ops (never blocks or errors the order sync that calls
-- it via the trigger below).

create extension if not exists supabase_vault;

-- ---------------------------------------------------------------------------
-- TELEGRAM_BOT_TOKEN - Vault-backed secret, same write-only/status-only shape as
-- PANCAKE_API_KEY (see supabase_secure_pancake_credentials.sql).
-- ---------------------------------------------------------------------------

drop function if exists public._telegram_bot_token();

create or replace function public._telegram_bot_token()
returns text
language sql
security definer
set search_path = public, extensions, vault
stable
as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'TELEGRAM_BOT_TOKEN';
$$;

revoke all on function public._telegram_bot_token() from anon, authenticated;

drop function if exists public.admin_set_telegram_bot_token(text, text, text);

create or replace function public.admin_set_telegram_bot_token(
  p_admin_username text,
  p_admin_password text,
  p_new_token text
)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_existing_id uuid;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_new_token is null or trim(p_new_token) = '' then
    raise exception 'Bot token cannot be empty.';
  end if;

  select id into v_existing_id from vault.secrets where name = 'TELEGRAM_BOT_TOKEN' limit 1;

  if v_existing_id is not null then
    perform vault.update_secret(v_existing_id, trim(p_new_token));
  else
    perform vault.create_secret(trim(p_new_token), 'TELEGRAM_BOT_TOKEN', 'Telegram bot token for order-confirmed notifications. Set via General Setup.');
  end if;
end;
$$;

drop function if exists public.admin_get_telegram_bot_token_status(text, text);

create or replace function public.admin_get_telegram_bot_token_status(
  p_admin_username text,
  p_admin_password text
)
returns table(is_configured boolean, updated_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_updated_at timestamptz;
  v_found boolean := false;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select s.updated_at, true into v_updated_at, v_found
  from vault.secrets s
  where s.name = 'TELEGRAM_BOT_TOKEN'
  limit 1;

  return query select coalesce(v_found, false), v_updated_at;
end;
$$;

grant execute on function public.admin_set_telegram_bot_token(text, text, text) to anon;
grant execute on function public.admin_get_telegram_bot_token_status(text, text) to anon;

-- ---------------------------------------------------------------------------
-- TELEGRAM_CHAT_ID - not a secret (just a destination id), so it lives in the existing plain
-- PortalSettings table instead (see supabase_portal_settings_table.sql) - editable straight from
-- General Setup's existing generic Settings panel, no new UI needed for this part.
-- ---------------------------------------------------------------------------

insert into public."PortalSettings" ("SettingKey", "SettingValue", "Description", "IsPublicToStaff")
select 'TELEGRAM_CHAT_ID', '', 'Telegram chat ID that order-confirmed notifications are sent to - see supabase_telegram_notifications.sql for how to find it.', false
where not exists (select 1 from public."PortalSettings" where "SettingKey" = 'TELEGRAM_CHAT_ID');

-- ---------------------------------------------------------------------------
-- Send helper - deliberately swallows every failure (missing config, network error, Telegram
-- rejecting the request) so a notification problem can NEVER break the order sync transaction
-- that triggers it. Use admin_test_telegram_notification below to actually see failures while
-- setting this up.
-- ---------------------------------------------------------------------------

drop function if exists public._telegram_send_message(text);

create or replace function public._telegram_send_message(p_text text)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_token text;
  v_chat_id text;
  v_url text;
begin
  v_token := public._telegram_bot_token();
  select "SettingValue" into v_chat_id from public."PortalSettings" where "SettingKey" = 'TELEGRAM_CHAT_ID';

  if v_token is null or trim(v_token) = '' or v_chat_id is null or trim(v_chat_id) = '' then
    return;
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
    v_url := 'https://api.telegram.org/bot' || v_token || '/sendMessage';

    perform extensions.http((
      'POST',
      v_url,
      array[extensions.http_header('Accept', 'application/json')],
      'application/json',
      jsonb_build_object('chat_id', v_chat_id, 'text', p_text)::text
    )::extensions.http_request);
  exception when others then
    null;
  end;
end;
$$;

revoke all on function public._telegram_send_message(text) from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Test/debug entry point - unlike _telegram_send_message above, this surfaces exactly what
-- happened (missing config vs. an actual HTTP failure vs. success), same "don't hide the error
-- while setting things up" precedent as debug_send_order_confirmation_message
-- (supabase_automated_orders_tables.sql).
-- ---------------------------------------------------------------------------

drop function if exists public.admin_test_telegram_notification(text, text, text);

create or replace function public.admin_test_telegram_notification(
  p_admin_username text,
  p_admin_password text,
  p_text text default 'Test notification from RS Pet Stop Portal.'
)
returns table(ok boolean, http_status int, response_body text)
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_token text;
  v_chat_id text;
  v_url text;
  v_response extensions.http_response;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_token := public._telegram_bot_token();
  select "SettingValue" into v_chat_id from public."PortalSettings" where "SettingKey" = 'TELEGRAM_CHAT_ID';

  if v_token is null or trim(v_token) = '' then
    return query select false, null::int, 'TELEGRAM_BOT_TOKEN is not set yet - save it under General Setup > Secure API Keys first.'::text;
    return;
  end if;
  if v_chat_id is null or trim(v_chat_id) = '' then
    return query select false, null::int, 'TELEGRAM_CHAT_ID is not set yet - add it under General Setup > Settings first.'::text;
    return;
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  v_url := 'https://api.telegram.org/bot' || v_token || '/sendMessage';

  select * into v_response from extensions.http((
    'POST',
    v_url,
    array[extensions.http_header('Accept', 'application/json')],
    'application/json',
    jsonb_build_object('chat_id', v_chat_id, 'text', p_text)::text
  )::extensions.http_request);

  return query select (v_response.status >= 200 and v_response.status < 300), v_response.status, left(v_response.content, 500);
end;
$$;

grant execute on function public.admin_test_telegram_notification(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- The actual trigger - fires on every insert/update to OnlineOrders (regardless of which of the
-- three Pancake sync paths performed the write - admin_sync_online_orders_from_pancake,
-- cron_sync_online_orders_from_pancake, or admin_list_online_orders_live, all in
-- supabase_pancake_manual_sync.sql), but only actually sends when this row's Status just became
-- Confirmed/Submitted and wasn't already (an UPDATE where OLD was already confirmed, or any later
-- update after that, does not re-fire). Walk-in orders (ReceivedAtShop = true) are excluded - the
-- ask was about online orders coming in, and walk-ins are already handled/paid at the counter.
-- ---------------------------------------------------------------------------

drop trigger if exists trg_notify_telegram_on_order_confirmed on public."OnlineOrders";
drop function if exists public._notify_telegram_on_order_confirmed();

create or replace function public._notify_telegram_on_order_confirmed()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_was_confirmed boolean := false;
  v_is_confirmed boolean;
  v_text text;
begin
  v_is_confirmed := lower(trim(coalesce(NEW."Status", ''))) in ('confirmed', 'submitted');

  if TG_OP = 'UPDATE' then
    v_was_confirmed := lower(trim(coalesce(OLD."Status", ''))) in ('confirmed', 'submitted');
  end if;

  if v_is_confirmed and not v_was_confirmed and NEW."ReceivedAtShop" is not true then
    v_text := 'New confirmed order' || E'\n'
      || 'Order: ' || coalesce(NEW."OrderID", '-') || E'\n'
      || 'Customer: ' || coalesce(NEW."CustomerName", '-') || E'\n'
      || 'Amount: PHP ' || to_char(coalesce(NEW."MoneyToCollect", 0), 'FM999,999,990.00') || E'\n'
      || 'Confirmed by: ' || coalesce(NEW."ConfirmedBy", '-');
    perform public._telegram_send_message(v_text);
  end if;

  return NEW;
end;
$$;

create trigger trg_notify_telegram_on_order_confirmed
  after insert or update on public."OnlineOrders"
  for each row
  execute function public._notify_telegram_on_order_confirmed();
