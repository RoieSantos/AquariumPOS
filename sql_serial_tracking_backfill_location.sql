-- One-off backfill for dbo.ItemSerialTracking rows that have no Location set yet.
-- Rule: Status contains "TRANSFER" (matches e.g. "TRANSFERRED-TO TESTINGSTORE1") -> Location = 'GMA'
--       anything else -> Location = 'AMAYA'
-- Only touches rows where Location is currently NULL/blank - any row that already has a real
-- Location value (GMA, a store name, etc.) is left untouched, so nothing already-correct gets
-- overwritten.

-- Run this first to preview exactly what will change before committing to it.
SELECT
    RunningSerialNo,
    SerialNo,
    ItemCode,
    Status,
    Location AS CurrentLocation,
    CASE WHEN Status LIKE '%TRANSFER%' THEN 'GMA' ELSE 'AMAYA' END AS NewLocation
FROM dbo.ItemSerialTracking
WHERE Location IS NULL OR LTRIM(RTRIM(Location)) = ''
ORDER BY RunningSerialNo;

-- Once the preview above looks right, run this to actually apply it.
UPDATE dbo.ItemSerialTracking
SET Location = CASE WHEN Status LIKE '%TRANSFER%' THEN 'GMA' ELSE 'AMAYA' END,
    UpdatedAtUtc = SYSUTCDATETIME(),
    UpdatedBy = 'BACKFILL_SCRIPT'
WHERE Location IS NULL OR LTRIM(RTRIM(Location)) = '';
