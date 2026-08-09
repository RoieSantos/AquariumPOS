// Shared Supabase connection config for the AquariumPOS Web Portal.
// SUPABASE_ANON_KEY is the *publishable* key (safe for client-side use) -
// the same one the desktop app uses as its "apikey" header. The SECRET
// service-role key used by the desktop app must NEVER be placed here.
window.APP_CONFIG = {
  SUPABASE_URL: 'https://hymcmesqgpliyyeghpgq.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz'
  // The Google Maps API key used by delivery.html/js/delivery.js used to live here - it has
  // moved to the portal-managed public.PortalSettings table (key GOOGLE_MAPS_API_KEY), edited
  // from general-setup.html, so it can be changed without redeploying this file. See
  // js/generalSetup.js / supabase_portal_settings_table.sql.
};
