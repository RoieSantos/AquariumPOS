-- One-off: mark the TEST serials as SOLD - per "can you mark the TEST serials as sold".
--
-- "TEST serials" = IN_STOCK serials whose item's name (or the serial's own description) has the WORD
-- "test" in it - e.g. AQ-042 "TEST AQUARIUM ONLY" built on PRD-000007. Whole word only, so an item
-- like "Tester Kit" or "Latest..." is NOT touched.
--
-- Same status change the portal makes when an order ships (Status 'SOLD', UpdatedAtUtc = now()), so
-- the local POS picks it up on its next serial sync (SyncItemSerialTrackingFromSupabaseAsync).
--
-- NOTE: this only changes the serials. The Item Ledger stock that Post Output added for them is NOT
-- reduced - if the test units should also leave stock, post a negative adjustment for them too.
--
-- Run step 1 alone first and check the list. Then run step 2.

-- 1. Preview - exactly what step 2 will change.
select s."SerialNo", s."ItemCode", coalesce(s."ItemDescription", i."Name") as description,
       s."VariantCode", s."Location", s."Status", s."SourceDocumentNo", s."CreatedAtUtc"
from public."ItemSerialTracking" s
left join public."Items" i on i."Code" = s."ItemCode"
where s."Status" = 'IN_STOCK'
  and (i."Name" ~* '\mtest\M' or s."ItemDescription" ~* '\mtest\M')
order by s."ItemCode", s."SerialNo";

-- 2. Mark them SOLD (returns the serials it changed).
update public."ItemSerialTracking" s
  set "Status" = 'SOLD',
      "UpdatedAtUtc" = now(),
      "UpdatedBy" = 'manual: test serials cleanup'
  from public."ItemSerialTracking" s2
  left join public."Items" i on i."Code" = s2."ItemCode"
  where s2."RunningSerialNo" = s."RunningSerialNo"
    and s."Status" = 'IN_STOCK'
    and (i."Name" ~* '\mtest\M' or s."ItemDescription" ~* '\mtest\M')
returning s."SerialNo", s."ItemCode", s."Location", s."Status";
