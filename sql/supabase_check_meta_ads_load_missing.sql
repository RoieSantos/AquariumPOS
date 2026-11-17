-- Read-only: why didn't a new Meta Ads wallet load show up in the Expense Journal?
-- One result set (section column), newest first within each section:
--   snapshot      - when each ad account last synced and what happened (ok: fundings_logged=N / error: ...)
--   cron_run      - last 5 runs of the daily 07:00 Manila 'meta-ads-sync' cron
--   funding_event - wallet loads the sync has seen in the last 3 days (ref = EXP- it created, blank = none)
--   expense_entry - META-ADS / Meta-looking Expense Journal entries in the last 3 days (auto or hand-typed)
-- Safe to run any time; changes nothing.

select * from (
  select 'snapshot' as section,
         to_char(s."LastSyncAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI') as at_manila,
         s."AvailableBalance" as amount,
         'act_' || s."AdAccountId" || ' / ' || coalesce(s."Store", '-') as ref,
         coalesce(s."LastSyncResult", '') as detail,
         1 as sort_group
  from public."MetaAdsAccountSnapshot" s

  union all
  select 'cron_run',
         to_char(r.start_time at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'),
         null,
         r.status,
         coalesce(r.return_message, ''),
         2
  from (select d.* from cron.job_run_details d
        join cron.job j on j.jobid = d.jobid
        where j.jobname = 'meta-ads-sync'
        order by d.start_time desc limit 5) r

  union all
  select 'funding_event',
         to_char(e."EventTimeUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'),
         e."AmountPhp",
         coalesce(j."ReceiptNo"::text, '(no expense entry)'),
         coalesce(e."AdAccountName", '') || ' | via ' || coalesce(e."PaymentMethod", '?')
           || ' | logged ' || to_char(e."CreatedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'),
         3
  from public."MetaAdsBillingEvents" e
  left join public."ExpenseJournalEntries" j on j."EntryID" = e."ExpenseJournalEntryID"
  where e."Kind" = 'funding' and e."EventDate" >= (now() at time zone 'Asia/Manila')::date - 3

  union all
  select 'expense_entry',
         j."EntryDate"::text,
         j."Amount",
         j."ReceiptNo"::text,
         coalesce(j."Warehouse", '-') || ' | ' || j."ExpenseCategory" || ' | ' || coalesce(j."Description", '')
           || ' | by ' || j."CreatedBy",
         4
  from public."ExpenseJournalEntries" j
  where j."EntryDate" >= (now() at time zone 'Asia/Manila')::date - 3
    and (j."CreatedBy" = 'auto-meta-ads-sync'
      or j."ExpenseCategory" ilike any (array['%meta%', '%facebook%', '%fb%', '%ads%'])
      or j."Description" ilike any (array['%meta%', '%facebook%', '%fb ad%', '%boost%']))
) x
order by sort_group, at_manila desc;
