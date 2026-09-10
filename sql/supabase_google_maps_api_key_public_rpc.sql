-- Public read of ONLY the Google Maps API key, for the new customer-facing live driver tracking
-- page (docs/track-driver.html) - per direct request to give the chatbot's get_driver_location
-- tool a real live-updating link instead of a static lat/long snapshot URL.
--
-- Deliberately a dedicated, single-purpose function rather than opening up
-- admin_get_public_portal_setting(text, text, text) to anon (supabase_portal_settings_table.sql) -
-- that RPC takes an arbitrary p_setting_key, so granting it to anon would let anyone read ANY
-- row flagged IsPublicToStaff = true, not just this one key. This function can only ever return
-- the one hardcoded setting name below.
--
-- Note this key is not being newly exposed in a meaningful sense - it already ships to every
-- staff member's browser as a plain query-string value on the Google Maps script tag
-- (docs/js/delivery.js's loadGoogleMapsScript), which is normal for Google Maps JS API keys:
-- Google's own security model for these keys is HTTP referrer restriction (set in Google Cloud
-- Console), not secrecy. Make sure the key's Application restrictions include your domain
-- (e.g. rspetstop.com/*) before relying on this.
--
-- Run this in the Supabase SQL Editor, after supabase_portal_settings_table.sql.

drop function if exists public.public_get_google_maps_api_key();

create or replace function public.public_get_google_maps_api_key()
returns text
language sql
security definer
set search_path = public, extensions
stable
as $$
  select "SettingValue"
  from public."PortalSettings"
  where "SettingKey" = 'GOOGLE_MAPS_API_KEY';
$$;

grant execute on function public.public_get_google_maps_api_key() to anon;
