-- One-off: normalize ItemSerialTracking.Location casing from "AMAYA" to "Amaya" (Serial Tracker /
-- Inventory Summary display). Only touches rows currently stored uppercase.
--
-- UpdatedAtUtc is bumped to now() so this doesn't get silently reverted by the desktop app's next
-- sync pass: SyncItemSerialTrackingToSupabaseAsync (OnlinefunctionsEvents.cs) skips patching a
-- Supabase row whenever Supabase's own UpdatedAtUtc is already newer than what the local row knew
-- about when it went dirty - so this edit wins, and the desktop app's own
-- SyncItemSerialTrackingFromSupabaseAsync pull will then bring "Amaya" down into the local
-- SQL Server table on its own, no manual local script needed.

update public."ItemSerialTracking"
set "Location" = 'Amaya',
    "UpdatedAtUtc" = now(),
    "UpdatedBy" = 'RENAME_SCRIPT'
where "Location" = 'AMAYA';
