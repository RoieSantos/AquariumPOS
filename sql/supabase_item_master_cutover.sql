-- CUTOVER: the portal becomes the only place products are created and edited (Pancake no longer).
--
-- Run ONLY when both store POS PCs run the build that pulls products from the portal
-- (SyncProductsFromPortalAsync) - an older POS still reads products from Pancake and would miss every
-- item / price added in the portal after this. That same build sends walk-ins to the portal (WI-), so
-- also run STEP 2 of supabase_pancake_sync_wind_down.sql at the same time.
--
-- 1. One last Pancake -> portal product sync, so nothing edited in Pancake today is lost.
-- 2. Pause sync-items-from-pancake. From then on (supabase_item_master_portal_owned.sql): New Item / edit /
--    New Variant / pictures work in Item Setup, and price edits no longer go to Pancake.
--
-- Undo (back to Pancake as the product master):
--   select cron.alter_job(jobid, active := true) from cron.job where jobname = 'sync-items-from-pancake';
-- Safe to re-run (the final sync just runs again while the job is still active; once paused, step 1 is
-- skipped so a re-run never pulls Pancake over portal edits).

do $$
begin
  if public._items_pancake_sync_active() then
    perform public.cron_sync_items_from_pancake();
  end if;
end;
$$;

select cron.alter_job(jobid, active := false)
from cron.job
where jobname = 'sync-items-from-pancake';

-- One result: who owns products now.
select case when public._items_pancake_sync_active() then 'Pancake still syncs products - cutover NOT done'
            else 'Portal owns products - edit them in Item Setup' end as product_master,
       (select count(*) from public."Items") as items,
       (select count(*) from public."Variants") as variants;
