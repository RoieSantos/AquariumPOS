-- Read-only check - per "can you double check if this is within the day of sales report?" (Daily Sales Report
-- Expenses list showing "Gma Rent - due Oct 24, 2026" etc.).
--
-- Bills & Dues payments (admin_pay_business_bill) log an Expense Journal entry dated the PAID date; the
-- "due ..." in its description is only the bill period. This lists every journal entry from a bill payment
-- in the last 14 days with its due date, paid date, entry date (what the Daily Sales Report filters on) and
-- when it was actually keyed in, so you can see they line up. date_check = 'OK' when entry date = paid date.
-- Safe to run any time.
select j."EntryDate"                                              as entry_date_used_by_report,
       p."PaidDate"                                               as paid_date,
       p."DueDate"                                                as due_date,
       (j."CreatedAtUtc" at time zone 'Asia/Manila')::timestamp(0) as keyed_in_at_manila,
       b."Name"                                                   as bill,
       coalesce(nullif(trim(j."Warehouse"), ''), '(No warehouse)') as branch,
       j."ExpenseCategory"                                        as category,
       j."Amount"                                                 as amount,
       p."PaidBy"                                                 as paid_by,
       p."CreatedBy"                                              as paid_by_user,
       case when j."EntryDate" = p."PaidDate" then 'OK' else 'MISMATCH' end as date_check
from public."BusinessBillPayments" p
join public."BusinessBills" b on b."BillID" = p."BillID"
join public."ExpenseJournalEntries" j on j."EntryID" = p."ExpenseJournalEntryID"
where j."EntryDate" >= (now() at time zone 'Asia/Manila')::date - 14
order by j."EntryDate" desc, j."CreatedAtUtc" desc;
