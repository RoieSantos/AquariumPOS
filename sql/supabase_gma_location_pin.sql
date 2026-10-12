-- GMA Conversations: "Pin location" link - per "add a button there that will let the user [open a]
-- delivery map and pinpoint the map where they live and get back to us for delivery".
--
-- Staff click the 📍 button in the composer -> admin_create_location_request makes a one-time link
-- (pin-location.html?t=<token>) that goes into the reply box. The customer opens it (no login), drops a
-- pin / uses their phone's location, adds a landmark, and submits -> public_submit_location_request saves
-- it and posts it into the conversation as the customer's own message (address + Google Maps link), so
-- it shows in the thread, bolds the chat as unread, and the bot sees it too.
--
-- A link works for 14 days and can be re-submitted up to 5 times (a customer fixing a wrong pin); each
-- submit posts a new message. Pins are only accepted inside the Philippines.
-- Safe to re-run. Needs docs/pin-location.html and js/gmaConversations.js ?v=pinloc1.

create table if not exists public."ChatbotLocationRequests" (
  "Token" uuid primary key default gen_random_uuid(),
  "Psid" varchar(255) not null references public."ChatbotConversations"("Psid") on delete cascade,
  "RequestedBy" text,
  "RequestedAtUtc" timestamptz not null default now(),
  "Latitude" double precision,
  "Longitude" double precision,
  "Address" text,
  "Notes" text,
  "SubmittedAtUtc" timestamptz,
  "SubmitCount" int not null default 0
);
create index if not exists "IX_ChatbotLocationRequests_Psid" on public."ChatbotLocationRequests"("Psid");
-- Only reached through the functions below.
alter table public."ChatbotLocationRequests" enable row level security;

-- ---------------------------------------------------------------------------
-- 1. Staff: new link for a conversation.
create or replace function public.admin_create_location_request(p_admin_username text, p_admin_password text, p_psid text)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token uuid;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not exists (select 1 from public."ChatbotConversations" where "Psid" = p_psid) then
    raise exception 'Conversation not found.';
  end if;

  insert into public."ChatbotLocationRequests" ("Psid", "RequestedBy")
  values (p_psid, p_admin_username)
  returning "Token" into v_token;
  return v_token;
end;
$$;

grant execute on function public.admin_create_location_request(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Customer page: is the link valid, and the pin already sent (to re-show it)?
create or replace function public.public_get_location_request(p_token uuid)
returns table(status text, customer_name text, latitude double precision, longitude double precision, address text, notes text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."ChatbotLocationRequests";
  v_name text;
begin
  select * into v_row from public."ChatbotLocationRequests" where "Token" = p_token;
  if not found then
    return query select 'not_found'::text, null::text, null::double precision, null::double precision, null::text, null::text;
    return;
  end if;
  -- First name only - the page greets them, nothing more.
  select split_part(trim(coalesce(c."CustomerName", '')), ' ', 1) into v_name
  from public."ChatbotConversations" c where c."Psid" = v_row."Psid";

  return query select
    case when v_row."RequestedAtUtc" < now() - interval '14 days' then 'expired'
         when v_row."SubmitCount" >= 5 then 'limit'
         else 'ok' end,
    nullif(v_name, ''), v_row."Latitude", v_row."Longitude", v_row."Address", v_row."Notes";
end;
$$;

grant execute on function public.public_get_location_request(uuid) to anon;

-- ---------------------------------------------------------------------------
-- 3. Customer page: save the pin and post it into the conversation. Returns the conversation's Psid
--    (the page uses it to ping open GMA inboxes so the message shows up right away).
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
begin
  select * into v_row from public."ChatbotLocationRequests" where "Token" = p_token for update;
  if not found then
    raise exception 'This link is not valid. Please ask us for a new one.';
  end if;
  if v_row."RequestedAtUtc" < now() - interval '14 days' then
    raise exception 'This link has expired. Please ask us for a new one.';
  end if;
  if v_row."SubmitCount" >= 5 then
    raise exception 'This link was already used several times. Please message us if your location changed.';
  end if;
  -- Philippines only (rough bounding box) - catches a pin dropped in the sea / wrong country.
  if p_latitude is null or p_longitude is null
     or p_latitude not between 4.0 and 21.5 or p_longitude not between 116.0 and 127.0 then
    raise exception 'Please drop the pin on your location in the Philippines.';
  end if;

  update public."ChatbotLocationRequests"
     set "Latitude" = p_latitude, "Longitude" = p_longitude, "Address" = v_address, "Notes" = v_notes,
         "SubmittedAtUtc" = now(), "SubmitCount" = "SubmitCount" + 1
   where "Token" = p_token;

  v_content := '📍 My delivery location' || case when v_row."SubmitCount" > 0 then ' (updated)' else '' end || E':\n'
    || coalesce(v_address || E'\n', '')
    || coalesce('Landmark / notes: ' || v_notes || E'\n', '')
    || 'https://www.google.com/maps?q=' || round(p_latitude::numeric, 6) || ',' || round(p_longitude::numeric, 6);

  insert into public."ChatbotMessages" ("Psid", "Role", "Content") values (v_row."Psid", 'user', v_content);
  -- Same as a normal customer message: moves the chat to the top and bolds it as unread.
  update public."ChatbotConversations"
     set "LastMessageAtUtc" = now(), "LastCustomerMessageAtUtc" = now()
   where "Psid" = v_row."Psid";

  return v_row."Psid";
end;
$$;

grant execute on function public.public_submit_location_request(uuid, double precision, double precision, text, text) to anon;

notify pgrst, 'reload schema';
