-- Read-only check: serials a POS tried to create and Supabase dropped (supabase_serial_tracking_portal_only.sql).
-- Any row here means that store's POS is still on an OLD build (the new build can't create serials) -
-- update it. The serial only exists in that POS's local database. Newest first, max 200.
--
-- Run AFTER supabase_serial_tracking_portal_only.sql. Safe to re-run any time.

select r."RejectedAtUtc" at time zone 'Asia/Manila' as rejected_at_manila,
       r."Location" as store,
       r."SerialNo",
       r."ItemCode",
       r."VariantCode",
       r."Status",
       r."SourceDocumentNo" as source_doc,
       r."CreatedBy" as created_by,
       r."DbRole" as pushed_as
from private."ItemSerialTrackingPosRejected" r
order by r."RejectedAtUtc" desc
limit 200;
