-- Read-only check for the Meta Ads billing sync (supabase_meta_ads_billing_sync.sql). One result set.
--   manual_meta_entry - Expense Journal entries typed by hand that look like Meta/FB ads loads. Run
--                       BEFORE the first backfill: anything listed here would be double-counted if
--                       the backfill starts before its date.
--   snapshot          - latest wallet balance + last sync result.
--   funding / charge  - synced events, newest first (funding rows show the EXP- receipt they created).

select * from (
  select 'manual_meta_entry' as section,
         j."EntryDate"::text as date,
         j."Amount" as amount,
         j."ReceiptNo"::text as ref,
         j."ExpenseCategory" || ' | ' || coalesce(j."Description", '') || ' | by ' || j."CreatedBy" as detail
  from public."ExpenseJournalEntries" j
  where j."CreatedBy" <> 'auto-meta-ads-sync'
    and (j."ExpenseCategory" ilike any (array['%meta%', '%facebook%', '%fb%', '%ads%', '%boost%'])
      or j."Description" ilike any (array['%meta%', '%facebook%', '%fb ad%', '%boost%', '%ads%']))

  union all
  select 'snapshot',
         to_char(s."LastSyncAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'),
         s."AvailableBalance",
         'act_' || s."AdAccountId",
         format('%s | balance in %s | unbilled %s | lifetime spent %s | %s', s."AdAccountName", s."Currency",
                s."UnbilledSpend", s."AmountSpent", s."LastSyncResult")
  from public."MetaAdsAccountSnapshot" s

  union all
  select e."Kind",
         e."EventDate"::text,
         e."AmountPhp",
         coalesce(j."ReceiptNo"::text, e."TransactionId"),
         e."AdAccountName" || ' | ' ||
         case when e."Currency" <> 'PHP' then format('%s %s @ %s (%s) | ', e."Currency", e."AmountOriginal", e."ExchangeRate", e."RateSource") else '' end ||
         case when e."Kind" = 'funding' then 'via ' || coalesce(e."PaymentMethod", '?')
              when e."VatInclusivePhp" is not null then 'Paid (incl. VAT) ' || e."VatInclusivePhp"
              else 'charge (net)' end
  from public."MetaAdsBillingEvents" e
  left join public."ExpenseJournalEntries" j on j."EntryID" = e."ExpenseJournalEntryID"
) x
order by case section when 'manual_meta_entry' then 0 when 'snapshot' then 1 else 2 end, date desc;
