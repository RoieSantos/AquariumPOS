-- Production Order serials -> local POS sync fix - per "if the serials are created in the portal.. how are
-- they going to sync in to the local pos?".
--
-- How it syncs: the POS's master-data timer (MainForm.cs -> OnlinefunctionsEvents.cs
-- SyncItemSerialTrackingFromSupabaseAsync) pulls ItemSerialTracking rows whose "UpdatedAtUtc" is newer
-- than its last pull (dbo.ItemSerialTrackingPullState watermark) and INSERTs any SerialNo it doesn't
-- have yet - matched by SerialNo, so a portal-created serial lands as a normal local row.
--
-- The gap: staff_post_production_output (supabase_production_orders.sql) inserts the new serials
-- without "UpdatedAtUtc" (no column default either), and the POS filter "UpdatedAtUtc=gt.<watermark>"
-- never matches NULL - so production serials were never pulled down.
--
-- Fix:
--   1. BEFORE INSERT trigger: a serial created by a production order (SourceDocumentNo 'PRD-...') with
--      no UpdatedAtUtc gets now() (and UpdatedBy = CreatedBy), so the next POS pull picks it up.
--      Scoped to PRD- serials so the POS's own pushes (which carry their own timestamps) are untouched.
--   2. Backfill: PRD- serials already created with a NULL UpdatedAtUtc get now() - NOT their
--      CreatedAtUtc, which is likely older than the POS watermark and would still be skipped.
--
-- Run AFTER supabase_production_orders.sql. Safe to re-run.

create or replace function public._item_serial_stamp_production_insert()
returns trigger
language plpgsql
as $$
begin
  if new."UpdatedAtUtc" is null and coalesce(new."SourceDocumentNo", '') like 'PRD-%' then
    new."UpdatedAtUtc" := now();
    new."UpdatedBy" := coalesce(new."UpdatedBy", new."CreatedBy");
  end if;
  return new;
end;
$$;

drop trigger if exists "TR_ItemSerialTracking_StampProductionInsert" on public."ItemSerialTracking";
create trigger "TR_ItemSerialTracking_StampProductionInsert"
  before insert on public."ItemSerialTracking"
  for each row execute function public._item_serial_stamp_production_insert();

-- Backfill serials already posted from production orders.
update public."ItemSerialTracking"
  set "UpdatedAtUtc" = now(),
      "UpdatedBy" = coalesce("UpdatedBy", "CreatedBy")
  where "UpdatedAtUtc" is null
    and coalesce("SourceDocumentNo", '') like 'PRD-%';

-- Check: production serials and whether the POS can see them (updated_at_utc must not be null).
select "SerialNo", "ItemCode", "VariantCode", "Location", "Status", "SourceDocumentNo", "CreatedAtUtc", "UpdatedAtUtc"
from public."ItemSerialTracking"
where coalesce("SourceDocumentNo", '') like 'PRD-%'
order by "CreatedAtUtc" desc
limit 50;
