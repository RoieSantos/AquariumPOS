-- One-off: remove the Expense Journal entries the Meta Ads sync created in its Nov 1-16 backfill
-- (CreatedBy = 'auto-meta-ads-sync'). Per direct request: "delete the entries for now since its
-- duplicated" - those loads were already entered by hand (META-ADS-EXPENSE). The sync KEEPS creating
-- entries for new loads from here on.
--
-- - Hand-typed entries are NOT touched (only CreatedBy = 'auto-meta-ads-sync').
-- - Only entries dated on/before 2026-11-15 are removed (the backfill's last load was Nov 15 GMA,
--   Nov 13 Amaya), so a real load made on Nov 16 or later is never deleted, even if this file is run
--   after the sync has logged it.
-- - The sync's MetaAdsBillingEvents rows stay, so the sync never re-creates these entries (it skips
--   any load it has already seen); their ExpenseJournalEntryID becomes null via ON DELETE SET NULL.
-- - An entry already posted to the General Ledger is NOT deleted (the G/L is reversing-entry only) -
--   it is listed as 'kept_posted_to_gl' instead, to be reversed on the General Ledger page.
--
-- No dependency on other files being re-run. Safe to re-run (second run deletes nothing).
-- Ends in ONE result: what was deleted / kept.

drop table if exists _meta_auto;

create temp table _meta_auto as
select j."EntryID", j."ReceiptNo", j."EntryDate", j."Amount", j."Warehouse",
       exists (select 1 from public."GLEntries" g
               where g."DocumentType" = 'Expense' and g."DocumentNo" = j."ReceiptNo") as posted_to_gl
from public."ExpenseJournalEntries" j
where j."CreatedBy" = 'auto-meta-ads-sync'
  and j."EntryDate" <= date '2026-11-15';

delete from public."ExpenseJournalEntries" j
using _meta_auto a
where j."EntryID" = a."EntryID" and not a.posted_to_gl;

select case when posted_to_gl then 'kept_posted_to_gl' else 'deleted' end as section,
       coalesce("Warehouse", '-') as store,
       count(*) as entries,
       sum("Amount") as total_php,
       min("EntryDate") as first_date,
       max("EntryDate") as last_date,
       string_agg("ReceiptNo", ', ' order by "ReceiptNo") as receipt_nos
from _meta_auto
group by posted_to_gl, "Warehouse"
union all
select 'remaining_auto_entries_up_to_nov15', '-', count(*), coalesce(sum("Amount"), 0), min("EntryDate"), max("EntryDate"), null
from public."ExpenseJournalEntries"
where "CreatedBy" = 'auto-meta-ads-sync' and "EntryDate" <= date '2026-11-15'
order by 1, 2;
