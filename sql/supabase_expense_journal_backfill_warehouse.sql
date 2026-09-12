-- One-off backfill: the very first Expense Journal entry (Truck expense gas for trip 11/09/2026,
-- 2500.00, added by 'admin' on 2026-09-10) went in with a blank Warehouse - see the "why it did not
-- add up" conversation - because the account that added it had no WarehouseName of its own, and the
-- Add Expense form's Warehouse field (before this fix) silently fell back to that. The form now
-- requires an explicit Warehouse choice going forward (see supabase_expense_journal_tables.sql /
-- docs/js/expenseJournal.js), so this only needs to run once to fix that already-saved row.
--
-- Matches on Warehouse IS NULL plus the entry's own category/amount/date/description as a safety net
-- so this can't accidentally touch any other row - if that combination doesn't match exactly one row
-- (e.g. it was already fixed, or something else changed), the update below simply updates 0 rows
-- rather than guessing.

update public."ExpenseJournalEntries"
set "Warehouse" = 'Warehouse'
where "Warehouse" is null
  and "ExpenseCategory" = 'TRUCK-EXPENSE - GAS/TOLL/PETTYCASH'
  and "Amount" = 2500.00
  and "EntryDate" = '2026-09-10'
  and "Description" = 'Truck expense gas for trip 11/09/2026';
