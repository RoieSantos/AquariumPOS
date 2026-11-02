-- Xendit: closes invoices left Pending from the legacy Invoice API, per the move to Payment Sessions. Xendit
-- is not live yet, so these are test invoices. xendit-create-invoice can't cancel one (it isn't a session), and
-- a Pending one would block that order's next payment. This only changes the row here, not Xendit.
--
-- Run AFTER supabase_xendit_pos_walkin.sql. Safe to re-run.

update public."XenditPayments"
   set "Status" = 'Expired'
 where "Status" = 'Pending'
   and "Source" = 'Online'
   and coalesce("InvoiceID", '') not like 'ps-%';

-- Verification - one result. Any is_test = false row with a legacy invoice means real money went through it.
select case when "InvoiceID" like 'ps-%' then 'session' else 'legacy invoice' end as api,
       "IsTest" as is_test,
       "Status" as status,
       count(*) as total,
       sum("Amount") as amount
  from public."XenditPayments"
 where "Source" = 'Online'
 group by 1, 2, 3
 order by 1, 2, 3;
