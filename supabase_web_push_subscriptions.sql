-- Web Push subscriptions - lets the Portal itself (not a third-party app like Telegram) push a
-- notification straight to a staff member's phone, once they've tapped "Enable Notifications" and
-- the portal is installed as a PWA. Per "meaning if we get confirmed order the notification will
-- be coming from telegram not our own app? / okay can we try web push?".
--
-- Unlike the Telegram setup (one shared bot -> one chat id), ANY number of staff can subscribe
-- independently - each browser/device that enables notifications gets its own row here and its
-- own push, no shared config needed per person.
--
-- Run this file once. See supabase_web_push_order_confirmed_trigger.sql for the trigger that
-- actually fires a push on a newly-confirmed order, and supabase/functions/send-web-push for the
-- Edge Function that does the real sending (Web Push requires per-message crypto that plain
-- Postgres can't do - that's why an Edge Function is needed here but wasn't for Telegram).

create table if not exists public."PushSubscriptions" (
    "Id" uuid primary key default gen_random_uuid(),
    "Endpoint" text not null unique,
    "P256dh" text not null,
    "Auth" text not null,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now(),
    "LastSeenAtUtc" timestamptz not null default now()
);

alter table public."PushSubscriptions" enable row level security;
revoke all on public."PushSubscriptions" from anon, authenticated;

comment on table public."PushSubscriptions" is 'Browser Push subscriptions for the Web Portal PWA - one row per subscribed device/browser. Read by the send-web-push Edge Function (via the service role key) to fan a notification out to every subscribed device.';

drop function if exists public.staff_save_push_subscription(text, text, text, text, text);

-- Upserts by Endpoint (unique per browser+device install) - re-enabling notifications on the same
-- device just refreshes LastSeenAtUtc rather than creating a duplicate row.
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
        "LastSeenAtUtc" = now();
end;
$$;

drop function if exists public.staff_delete_push_subscription(text, text, text);

-- Called when a user disables notifications from this device (or the subscription errors out
-- client-side) - stops that device from receiving any further pushes.
create or replace function public.staff_delete_push_subscription(
  p_admin_username text,
  p_admin_password text,
  p_endpoint text
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

  delete from public."PushSubscriptions" where "Endpoint" = p_endpoint;
end;
$$;

drop function if exists public.admin_list_push_subscriptions(text, text);

-- Lets General Setup show "how many devices are subscribed" - metadata only, endpoints/keys
-- aren't secret exactly but there's no reason to send them back to the browser either.
create or replace function public.admin_list_push_subscriptions(p_admin_username text, p_admin_password text)
returns table(created_by text, created_at_utc timestamptz, last_seen_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "CreatedBy"::text, "CreatedAtUtc", "LastSeenAtUtc"
    from public."PushSubscriptions"
    order by "LastSeenAtUtc" desc;
end;
$$;

grant execute on function public.staff_save_push_subscription(text, text, text, text, text) to anon;
grant execute on function public.staff_delete_push_subscription(text, text, text) to anon;
grant execute on function public.admin_list_push_subscriptions(text, text) to anon;
