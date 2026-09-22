-- Repairs Items rows corrupted by the old SKU-collision sync bug (see
-- supabase_pancake_item_sku_match_fix.sql / supabase_diagnose_item_code_mismatch.sql), per direct
-- follow-up: "i think there are some more mismatch as per checking how can we correct it".
--
-- WHY A PLAIN RE-SYNC ALONE DOESN'T FIX THIS
-- "Code" is never overwritten by a sync - it's always the lookup key, so it's still trustworthy.
-- "ProductId" is what got poisoned: a corrupted row now holds a DIFFERENT product's real Pancake id
-- (e.g. AS-014's row currently holds LEBAOYU's id, not the aquarium's). The fixed sync
-- (admin_sync_items_from_pancake / cron_sync_items_from_pancake) matches ProductId FIRST, Code only
-- as a fallback. So on a fresh sync: the aquarium (real code AS-014) finds no row with its own
-- ProductId and correctly falls back to Code, landing on the AS-014 row - but LEBAOYU (real code
-- L-5w) finds that SAME row first via the poisoned ProductId and claims it too. Both resolve to one
-- row in the same sync pass, and PostgreSQL's DISTINCT ON picks whichever arrives first - not
-- deterministic, not necessarily correct. Re-running the sync as-is can just as easily re-corrupt a
-- row as fix it.
--
-- THE FIX: wipe the poisoned ProductId column so it can't wrongly out-compete a correct Code match,
-- then run one full sync. With every row's ProductId null, ProductId-matching is vacuous for
-- everyone, so every Pancake product resolves purely by its own exact Code - correct and
-- deterministic, healing every affected row (not just the ones already spotted) in one pass. Safe
-- to run even on rows that were never corrupted - they just get correctly re-confirmed by Code
-- either way.
--
-- Run each step directly in the Supabase SQL editor, IN ORDER.

-- ---------------------------------------------------------------------------------------------
-- Step 0. Make sure the FIXED matching logic (ProductId-first, exact-Code-fallback, no SKU match)
--         is actually what runs during the healing sync below. Safe to run again even if you
--         already applied it once - "create or replace".
-- ---------------------------------------------------------------------------------------------
-- \i supabase_pancake_item_sku_match_fix.sql
-- (Open that file and run its full contents here first, then continue below.)

-- ---------------------------------------------------------------------------------------------
-- Step 1. Break every poisoned ProductId link. This does NOT touch Code/Name/Price/Category - it
--         only clears the one field that was letting an unrelated product steal a row.
-- ---------------------------------------------------------------------------------------------
update public."Items" set "ProductId" = null where "ProductId" is not null;

-- ---------------------------------------------------------------------------------------------
-- Step 2. Run one full sync now (the same function the */5 * * * * cron calls) - with ProductId
--         cleared, every product this pulls from Pancake resolves purely by its own exact Code.
--         This can take a little while (it walks the whole catalog, ~30 products per page).
-- ---------------------------------------------------------------------------------------------
select * from public.cron_sync_items_from_pancake();

-- ---------------------------------------------------------------------------------------------
-- Step 3. Verify. AS-014 should now show the aquarium; searching for any remaining SKU collisions
--         should come back much shorter (collisions are still POSSIBLE if Pancake itself has two
--         products with the same code, a real data problem on Pancake's side, not this bug - but
--         the false ProductId-driven ones from the old bug should be gone).
-- ---------------------------------------------------------------------------------------------
select "Code", "SKU", "Name", "CategoryCode", "Price", "ProductId", "SyncedAtUtc"
from public."Items"
where "Code" in ('AS-014', 'L-5w');

select i."SKU", count(*) over (partition by i."SKU") as codes_sharing_this_sku,
       i."Code", i."Name", i."CategoryCode", i."ProductId", i."SyncedAtUtc"
from public."Items" i
where i."SKU" is not null
  and i."SKU" in (select "SKU" from public."Items" where "SKU" is not null group by "SKU" having count(*) > 1)
order by i."SKU", i."SyncedAtUtc" desc nulls last;
