-- Meta Ads page (docs/meta-ads.html) - per direct request "add how much the balance for each page":
-- one card per store's ad account (wallet balance, unbilled spend, days left at the last 7 days' pace)
-- plus loads / charges in a date range. Reads what meta-ads-sync stores.
--
-- Also adds "Store" to MetaAdsAccountSnapshot (written by the redeployed meta-ads-sync from the
-- META_AD_ACCOUNTS secret) so each card is labelled GMA / Amaya.
--
-- Run this in the Supabase SQL Editor AFTER supabase_meta_ads_billing_sync.sql. Safe to re-run.

alter table public."MetaAdsAccountSnapshot" add column if not exists "Store" varchar(200);

-- Backfill Store for accounts already synced, from the warehouse on their logged expense entries.
update public."MetaAdsAccountSnapshot" s
set "Store" = x.warehouse
from (
  select distinct on (e."AdAccountId") e."AdAccountId", j."Warehouse" as warehouse
  from public."MetaAdsBillingEvents" e
  join public."ExpenseJournalEntries" j on j."EntryID" = e."ExpenseJournalEntryID"
  where j."Warehouse" is not null
  order by e."AdAccountId", e."EventTimeUtc" desc
) x
where x."AdAccountId" = s."AdAccountId" and s."Store" is null;

-- ---------------------------------------------------------------------------
-- service_set_meta_ads_snapshot: same as before plus p_store (defaulted, so an old caller still works).

drop function if exists public.service_set_meta_ads_snapshot(text, text, text, numeric, numeric, numeric, numeric, text);
drop function if exists public.service_set_meta_ads_snapshot(text, text, text, numeric, numeric, numeric, numeric, text, text);

create or replace function public.service_set_meta_ads_snapshot(
  p_ad_account_id text,
  p_ad_account_name text,
  p_currency text,
  p_available_balance numeric,
  p_unbilled_spend numeric,
  p_amount_spent numeric,
  p_spend_cap numeric,
  p_result text,
  p_store text default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  insert into public."MetaAdsAccountSnapshot"
    ("AdAccountId", "AdAccountName", "Currency", "AvailableBalance", "UnbilledSpend", "AmountSpent",
     "SpendCap", "LastSyncAtUtc", "LastSyncResult", "Store")
  values
    (p_ad_account_id, p_ad_account_name, p_currency, p_available_balance, p_unbilled_spend, p_amount_spent,
     p_spend_cap, timezone('utc', now()), left(p_result, 1000), nullif(trim(coalesce(p_store, '')), ''))
  on conflict ("AdAccountId") do update set
    "AdAccountName" = excluded."AdAccountName",
    "Currency" = excluded."Currency",
    "AvailableBalance" = excluded."AvailableBalance",
    "UnbilledSpend" = excluded."UnbilledSpend",
    "AmountSpent" = excluded."AmountSpent",
    "SpendCap" = excluded."SpendCap",
    "LastSyncAtUtc" = excluded."LastSyncAtUtc",
    "LastSyncResult" = excluded."LastSyncResult",
    "Store" = coalesce(excluded."Store", public."MetaAdsAccountSnapshot"."Store");
end;
$$;

revoke all on function public.service_set_meta_ads_snapshot(text, text, text, numeric, numeric, numeric, numeric, text, text) from public, anon, authenticated;
grant execute on function public.service_set_meta_ads_snapshot(text, text, text, numeric, numeric, numeric, numeric, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- admin_get_meta_ads: everything the page shows, as one jsonb. Dates are Manila dates, inclusive.
--   accounts[]: snapshot + latest rate (PHP equivalent for EUR) + 7-day average daily charge + range totals
--   events[]:   loads and charges in range, newest first

drop function if exists public.admin_get_meta_ads(text, text, date, date);

create or replace function public.admin_get_meta_ads(
  p_admin_username text,
  p_admin_password text,
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_accounts jsonb;
  v_events jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select coalesce(jsonb_agg(a order by a->>'store', a->>'name'), '[]'::jsonb) into v_accounts
  from (
    select jsonb_build_object(
      'ad_account_id', s."AdAccountId",
      'name', s."AdAccountName",
      'store', s."Store",
      'currency', s."Currency",
      'available_balance', s."AvailableBalance",
      'unbilled_spend', s."UnbilledSpend",
      'amount_spent', s."AmountSpent",
      'last_sync_at', s."LastSyncAtUtc",
      'last_sync_result', s."LastSyncResult",
      'latest_rate', (select e."ExchangeRate" from public."MetaAdsBillingEvents" e
                       where e."AdAccountId" = s."AdAccountId" order by e."EventTimeUtc" desc limit 1),
      -- average daily charge over the last 7 full days, in the account currency
      'avg_daily_charge_7d', (select round(coalesce(sum(e."AmountOriginal"), 0) / 7.0, 2)
                               from public."MetaAdsBillingEvents" e
                               where e."AdAccountId" = s."AdAccountId" and e."Kind" = 'charge'
                                 and e."EventDate" between v_today - 7 and v_today - 1),
      'loads_count', (select count(*) from public."MetaAdsBillingEvents" e
                       where e."AdAccountId" = s."AdAccountId" and e."Kind" = 'funding'
                         and e."EventDate" between p_from and p_to),
      'loads_original', (select coalesce(sum(e."AmountOriginal"), 0) from public."MetaAdsBillingEvents" e
                          where e."AdAccountId" = s."AdAccountId" and e."Kind" = 'funding'
                            and e."EventDate" between p_from and p_to),
      'loads_php', (select coalesce(sum(coalesce(j."Amount", e."AmountPhp")), 0)
                     from public."MetaAdsBillingEvents" e
                     left join public."ExpenseJournalEntries" j on j."EntryID" = e."ExpenseJournalEntryID"
                     where e."AdAccountId" = s."AdAccountId" and e."Kind" = 'funding'
                       and e."EventDate" between p_from and p_to),
      'charges_original', (select coalesce(sum(e."AmountOriginal"), 0) from public."MetaAdsBillingEvents" e
                            where e."AdAccountId" = s."AdAccountId" and e."Kind" = 'charge'
                              and e."EventDate" between p_from and p_to),
      'charges_php', (select coalesce(sum(coalesce(e."VatInclusivePhp", e."AmountPhp")), 0) from public."MetaAdsBillingEvents" e
                       where e."AdAccountId" = s."AdAccountId" and e."Kind" = 'charge'
                         and e."EventDate" between p_from and p_to)
    ) as a
    from public."MetaAdsAccountSnapshot" s
  ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
      'date', e."EventDate",
      'time', e."EventTimeUtc",
      'kind', e."Kind",
      'ad_account_id', e."AdAccountId",
      'store', s."Store",
      'currency', e."Currency",
      'amount_original', e."AmountOriginal",
      'rate', e."ExchangeRate",
      'amount_php', coalesce(j."Amount", e."AmountPhp"),
      'vat_inclusive_php', e."VatInclusivePhp",
      'method', e."PaymentMethod",
      'transaction_id', e."TransactionId",
      'expense_receipt_no', j."ReceiptNo",
      'expense_deleted', e."Kind" = 'funding' and j."EntryID" is null
    ) order by e."EventTimeUtc" desc), '[]'::jsonb) into v_events
  from public."MetaAdsBillingEvents" e
  left join public."MetaAdsAccountSnapshot" s on s."AdAccountId" = e."AdAccountId"
  left join public."ExpenseJournalEntries" j on j."EntryID" = e."ExpenseJournalEntryID"
  where e."EventDate" between p_from and p_to;

  return jsonb_build_object('accounts', v_accounts, 'events', v_events);
end;
$$;

grant execute on function public.admin_get_meta_ads(text, text, date, date) to anon;
