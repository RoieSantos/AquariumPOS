-- One-off audit query (not a function - just run this directly): lists every Items row whose
-- "SKU" is shared by 2+ codes. These are exactly the rows at risk from the SKU-match bug fixed
-- in supabase_pancake_item_sku_match_fix.sql - any of them may have had their Name/Price/
-- CategoryCode/ProductId silently overwritten by an unrelated product during a past sync.
--
-- Look for rows whose "Name"/"CategoryCode" look unrelated to what the "Code" itself suggests
-- (e.g. AS-014 named "Sphero Carbon Black" instead of something sticker-related), or whose
-- "SyncedAtUtc" is surprisingly recent/close together across the group (a sign they were all
-- touched by the same colliding sync run). This query only finds candidates - it does not fix
-- anything; recovering a row's correct data (if it was overwritten) has to be done by hand,
-- e.g. by cross-checking against Pancake directly or the desktop app's local database.
select
  i."SKU",
  count(*) over (partition by i."SKU") as codes_sharing_this_sku,
  i."Code",
  i."Name",
  i."CategoryCode",
  i."Price",
  i."ProductId",
  i."SyncedAtUtc"
from public."Items" i
where i."SKU" is not null
  and i."SKU" in (
    select "SKU" from public."Items" where "SKU" is not null group by "SKU" having count(*) > 1
  )
order by i."SKU", i."SyncedAtUtc" desc nulls last;
