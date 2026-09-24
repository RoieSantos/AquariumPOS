-- One-off cleanup, per direct request: delete the Item Ledger entries posted on 2026-09-24 at
-- 8:13 PM (Philippine time) - the Opening Balance rows the Pancake seed loaded - because the
-- beginning balance is being loaded again. Every other entry is left alone.
--
-- "ItemLedgerEntries" is append-only (triggers block UPDATE/DELETE/TRUNCATE), so - same escape hatch
-- as supabase_item_ledger_wipe_test_data.sql - the two guard triggers are disabled, the rows deleted,
-- and the triggers re-enabled, all in one transaction so a failure rolls everything back.
--
-- It ALSO switches sales posting back OFF (ItemLedgerSetup."SalesPostingStartUtc" = NULL): the seed
-- turned it on, and "Start Posting Sales From Now" refuses to run while a start date is set. Press
-- that button again once the new starting stock is loaded. ItemLedgerOrderSync is cleared too, so
-- orders are looked at fresh after the new start.
--
-- NOTE: any Sale entries the every-minute cron posted AFTER 8:13 PM are NOT deleted by this (they
-- have their own later timestamps). STEP 1 lists everything by minute so you can see if there are
-- any; if so, tell me and I'll extend the delete.
--
-- ORDER: run STEP 1 (preview) and check the 8:13 PM group is the only one marked DELETE, then run
-- STEP 2 (the whole block from BEGIN to COMMIT at once).

-- ============================================================================
-- STEP 1 - PREVIEW (read-only): entries grouped by the minute posted (Philippine time)
-- ============================================================================

select
  to_char(e."PostedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH12:MI AM') as posted_at_manila,
  e."DocumentType",
  count(*) as entries,
  case
    when e."PostedAtUtc" at time zone 'Asia/Manila' >= timestamp '2026-09-24 20:13:00'
     and e."PostedAtUtc" at time zone 'Asia/Manila' <  timestamp '2026-09-24 20:14:00'
    then 'DELETE' else 'keep'
  end as action
from public."ItemLedgerEntries" e
group by 1, 2, 4
order by min(e."PostedAtUtc");

-- ============================================================================
-- STEP 2 - DELETE (one transaction)
-- ============================================================================

begin;

alter table public."ItemLedgerEntries" disable trigger "TR_ItemLedgerEntries_NoUpdateDelete";
alter table public."ItemLedgerEntries" disable trigger "TR_ItemLedgerEntries_NoTruncate";

-- A reversing entry points at the entry it cancels ("ReversesEntryNo"); clear that pointer on any
-- kept entry whose target is about to be deleted, otherwise the delete would be refused.
update public."ItemLedgerEntries" k
   set "ReversesEntryNo" = null
 where k."ReversesEntryNo" is not null
   and exists (
     select 1 from public."ItemLedgerEntries" t
      where t."EntryNo" = k."ReversesEntryNo"
        and t."PostedAtUtc" at time zone 'Asia/Manila' >= timestamp '2026-09-24 20:13:00'
        and t."PostedAtUtc" at time zone 'Asia/Manila' <  timestamp '2026-09-24 20:14:00'
   )
   and not (k."PostedAtUtc" at time zone 'Asia/Manila' >= timestamp '2026-09-24 20:13:00'
        and k."PostedAtUtc" at time zone 'Asia/Manila' <  timestamp '2026-09-24 20:14:00');

delete from public."ItemLedgerEntries" e
 where e."PostedAtUtc" at time zone 'Asia/Manila' >= timestamp '2026-09-24 20:13:00'
   and e."PostedAtUtc" at time zone 'Asia/Manila' <  timestamp '2026-09-24 20:14:00';

alter table public."ItemLedgerEntries" enable trigger "TR_ItemLedgerEntries_NoUpdateDelete";
alter table public."ItemLedgerEntries" enable trigger "TR_ItemLedgerEntries_NoTruncate";

update public."ItemLedgerSetup" set "SalesPostingStartUtc" = null, "UpdatedAtUtc" = now() where "Id";
delete from public."ItemLedgerOrderSync";

-- Items."QuantityInStock" follows the ledger via an INSERT trigger, which a DELETE never fires.
select public._ile_sync_all_item_quantities();

commit;

-- ============================================================================
-- Verification
-- ============================================================================

select count(*) as remaining_entries from public."ItemLedgerEntries";
select count(*) as should_be_0 from public."ItemLedgerEntries"
 where "PostedAtUtc" at time zone 'Asia/Manila' >= timestamp '2026-09-24 20:13:00'
   and "PostedAtUtc" at time zone 'Asia/Manila' <  timestamp '2026-09-24 20:14:00';
select "SalesPostingStartUtc" as should_be_null from public."ItemLedgerSetup";
