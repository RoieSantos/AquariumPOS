-- Public read of currently-tracking driver locations, for the Facebook Messenger chatbot's
-- get_driver_location tool (supabase/functions/facebook-messenger-webhook/index.ts) - per direct
-- request to let the AI bot answer "where is the driver?" This is deliberately a NEW function
-- rather than reusing admin_get_driver_locations (supabase_driver_locations_table.sql), because
-- that one requires staff username/password and the webhook runs as anon with no staff
-- credentials of its own.
--
-- Only exposes DisplayName (never Username) and coordinates/timestamps - same "don't leak staff
-- usernames on anon-facing RPCs" principle as admin_list_sticker_pricing vs
-- public_get_sticker_pricing. Filtered to IsTracking = true only, so a driver who has logged out
-- never shows up here. This is a first pass for testing the bot's ability to read a driver's live
-- location at all - it is NOT yet tied to a specific order/customer (see the file header note in
-- the webhook's TOOLS array), so treat "a driver is tracking" as "someone is out on the road" only,
-- not "this driver is headed to this customer".
--
-- Run this in the Supabase SQL Editor, after supabase_driver_locations_table.sql.

drop function if exists public.public_get_active_driver_locations();

create or replace function public.public_get_active_driver_locations()
returns table(
  display_name text,
  latitude numeric,
  longitude numeric,
  recorded_at_utc timestamptz,
  updated_at_utc timestamptz
)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select su."DisplayName"::text, dl."Latitude", dl."Longitude", dl."RecordedAtUtc", dl."UpdatedAtUtc"
  from public."DriverLocations" dl
  join public."StaffUsers" su on su."Username" = dl."Username"
  where dl."IsTracking" is true
  order by dl."UpdatedAtUtc" desc;
$$;

grant execute on function public.public_get_active_driver_locations() to anon;
