-- Diagnose an Items row that looks wrong vs. Pancake, per direct report: Item Setup shows AS-014 as
-- "LEBAOYU (A30-5W)" (category STICKER) while Pancake's own product list shows AS-014 as
-- "100GALLONS-AQUARIUM-10MM (Undersump COMPETE SETUP SET)" - "im confuse why is the data on pancake
-- and portal is now different. can you check if there are mix up?"
--
-- THE LIKELY CAUSE, already documented in this repo: a past bug in the item sync
-- (supabase_pancake_item_sku_match_fix.sql / supabase_debug_pancake_sku_collisions.sql) matched
-- Items rows by SKU as well as Code - and Pancake's SKUs for variant-less products turned out to be
-- small, non-unique numbers, so an unrelated new/changed product could silently overwrite an
-- existing row's Name/Price/Category/ProductId. AS-014 was literally named as an at-risk example in
-- that fix's own comments. The fix stops future syncs from doing this, but does NOT repair a row
-- that was already overwritten - that has to be found and corrected by hand, which is what this
-- file is for. (It's also possible this is unrelated - e.g. Pancake genuinely reused the code AS-014
-- for a new product - the queries below tell the two apart.)
--
-- Run each block directly in the Supabase SQL editor, in order - nothing here writes anything.
-- Swap 'AS-014' for whatever other code you want to check the same way.

-- ---------------------------------------------------------------------------------------------
-- 1. Is the FIXED item sync actually the one running right now, or is the old buggy version still
--    live (e.g. the fix file was written but never actually run against this database)?
--    Read the output and search it for the literal text  (SKU = t.sku) OR (Code = t.code)
--    FOUND that text  -> the OLD buggy version is still live. Run supabase_pancake_item_sku_match_
--                        fix.sql now (safe to run again even if you think you already did).
--    NOT found        -> the fixed version is live; this row's problem (if any) predates the fix
--                        and just needs manual correction below, not a re-run of the fix.
-- ---------------------------------------------------------------------------------------------
select pg_get_functiondef('public.admin_sync_items_from_pancake(text,text)'::regprocedure) as current_sync_function_source;

-- ---------------------------------------------------------------------------------------------
-- 2. What the portal currently has for this code, and when it was last touched by a sync.
-- ---------------------------------------------------------------------------------------------
select "Code", "SKU", "Name", "CategoryCode", "Price", "ProductId", "SyncedAtUtc"
from public."Items"
where "Code" = 'AS-014';

-- ---------------------------------------------------------------------------------------------
-- 3. Does this row's SKU collide with any other code's? This is the exact shape of the known bug -
--    several unrelated Items rows sharing one small Pancake-assigned SKU number. If this returns
--    more than one row, whichever one was synced MOST RECENTLY (top of the list) is probably the
--    one actually holding correct/current data, and the rest may be stale/overwritten.
-- ---------------------------------------------------------------------------------------------
select i."SKU", count(*) over (partition by i."SKU") as codes_sharing_this_sku,
       i."Code", i."Name", i."CategoryCode", i."ProductId", i."SyncedAtUtc"
from public."Items" i
where i."SKU" = (select "SKU" from public."Items" where "Code" = 'AS-014')
order by i."SyncedAtUtc" desc nulls last;

-- ---------------------------------------------------------------------------------------------
-- 4. What does Pancake say, live, right now, for the code AS-014 - and which existing Items row
--    would the sync match it against? (embeds the live Pancake API key - this block only, not for
--    wider use.)
-- ---------------------------------------------------------------------------------------------
select * from public.debug_explain_pancake_product_sync('AS-014');

-- ---------------------------------------------------------------------------------------------
-- 5. Where did the sticker (LEBAOYU / A30-5W) actually go in Pancake? Confirms whether it still
--    exists there under a different code (the AS-014 code was reassigned/reused) or has been
--    deleted/archived (would come back with raw_product = null).
-- ---------------------------------------------------------------------------------------------
select * from public.debug_find_pancake_product('LEBAOYU');
