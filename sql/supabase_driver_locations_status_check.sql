-- One-off diagnostic query: check whether a driver's phone is actively sending GPS pings, straight
-- from the DriverLocations table (see supabase_driver_locations_table.sql) - useful when testing
-- the driver-app (driver-app/) without needing the portal's map open.
--
-- How to read the result:
--   - "IsTracking" = true and "seconds_since_update" small (well under a minute) -> actively
--     tracking right now, pings are flowing normally.
--   - "IsTracking" = true but "seconds_since_update" is large/growing -> the app/service stopped
--     sending pings without a clean driver_stop_tracking call (e.g. force-killed, an OEM battery
--     manager killed it, or it lost network) - this is the "stuck as tracking but actually dead"
--     case worth watching for while testing swipe-away/reboot survival.
--   - "IsTracking" = false -> the driver tapped "Log Out" (driver_stop_tracking was called
--     cleanly).
--
-- Run this in the Supabase SQL Editor. Safe to re-run any time - read-only.

select
  "Username",
  "Latitude",
  "Longitude",
  "IsTracking",
  "RecordedAtUtc",
  "UpdatedAtUtc",
  extract(epoch from (now() - "UpdatedAtUtc"))::int as seconds_since_update
from public."DriverLocations"
order by "UpdatedAtUtc" desc;
