-- One-off: force a full Pancake -> portal product resync, per "there are some mismatch in the product
-- name can we resync the products from pancake to portal".
--
-- cron_sync_items_from_pancake (supabase_pancake_manual_sync.sql) already re-pulls EVERY product and
-- variation every 5 minutes and overwrites Items."Name" / Items."Description" / Variants."VariantName",
-- so stale names usually mean that job has been failing (Pancake timeout, HTTP error, etc).
-- Run each step separately in the Supabase SQL editor and look at its output.

-- Step 1: has the 5-minute job been failing? Look for status = 'failed' and its return_message.
select d.status, d.return_message, d.start_time, d.end_time
from cron.job_run_details d
join cron.job j on j.jobid = d.jobid
where j.jobname = 'sync-items-from-pancake'
order by d.start_time desc
limit 20;

select "Entity", "LastSyncUtc" from public."PancakeSyncState" order by "LastSyncUtc" desc;

-- Step 2: run the full resync now (same function the cron job calls). Takes ~10-60s.
-- Returns items/variants synced/inserted/updated counts; an error here is the same error the cron hits.
select * from public.cron_sync_items_from_pancake();

-- Step 3: whatever still looks off after the resync.

-- 3a. Items the resync did NOT touch (SyncedAtUtc older than 10 minutes) - these no longer match any
--     Pancake product by ProductId/SKU/Code (deleted in Pancake, or code changed), so their name can't
--     be refreshed automatically.
select "Code", "SKU", "ProductId", "Name", "SyncedAtUtc"
from public."Items"
where "SyncedAtUtc" is null or "SyncedAtUtc" < now() - interval '10 minutes'
order by "Code";

-- 3b. Variants whose VariantName doesn't contain the parent item's current name (Pancake's per-variation
--     name can legitimately differ, so treat this as a review list rather than errors).
select v."VariationId", v."ItemCode", v."SKU", v."VariantName", i."Name" as item_name, v."SyncedAtUtc"
from public."Variants" v
join public."Items" i on i."Code" = v."ItemCode"
where position(lower(trim(i."Name")) in lower(coalesce(v."VariantName", ''))) = 0
order by v."ItemCode", v."SKU";

-- 3c. Variants the resync did NOT touch (variation removed in Pancake).
select "VariationId", "ItemCode", "SKU", "VariantName", "SyncedAtUtc"
from public."Variants"
where "SyncedAtUtc" is null or "SyncedAtUtc" < now() - interval '10 minutes'
order by "ItemCode", "SKU";
