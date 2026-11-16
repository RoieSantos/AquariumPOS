-- Meta Ads billing sync - per direct request ("I'm loading my wallet for meta ads and I want it to
-- reflect on my portal for expense reporting"). Decision: the WALLET LOAD (GCash / card top-up) is
-- the expense, same as Claude top-ups (supabase_claude_spend_tracking.sql).
--
-- Source: Graph API GET act_{id}/activities (needs an ads_read token, secret META_ADS_ACCESS_TOKEN).
-- The meta-ads-sync Edge Function pulls it daily and calls service_log_meta_ads_events below with
-- the two money event types:
--   funding_event_successful   "Money added to balance" - extra_data.amount (centavos), network_id
--                              ("GCash", or 0 = card). No transaction id in the log, so it is keyed
--                              on event time + amount.
--                              -> ONE ExpenseJournalEntries row (category META-ADS), so it shows up on
--                                 the Expense Journal, Posted Expenses, Dashboard and G/L like a manual
--                                 entry. (The Nov 1-16 backfill duplicated hand-typed META-ADS-EXPENSE
--                                 entries and was removed by supabase_meta_ads_remove_auto_expenses.sql;
--                                 those loads stay in MetaAdsBillingEvents so they're never re-created.)
--   ad_account_billing_charge  "Account billed" - extra_data.new_value (centavos, EXCLUDING 12% VAT)
--                              + transaction_id. Stored for reconciliation only (NOT expensed - the
--                              money was already expensed when it was loaded). Verified against Meta's
--                              Payment activity page: 629.37 net x 1.12 = 704.89 shown as Paid, same
--                              for 523.74/586.59, 639.57/716.32, 558.14/625.12.
-- Plus one snapshot row per ad account (wallet balance, lifetime spend, unbilled spend).
--
-- Two ad accounts, one per store (META_AD_ACCOUNTS secret): RSpetstop Gma (PHP, GCash loads) -> GMA,
-- Mharoie Oliveros Santos act_135164877 (EUR, card loads) -> Amaya. Non-PHP amounts are converted at
-- the ECB rate for the event's date (looked up by the Edge Function, passed per event as php_rate /
-- rate_source); the original currency, amount and rate are kept on the row. The bank's own card FX
-- rate will differ slightly, so EUR loads are close-but-not-exact pesos. VAT-inclusive is only
-- computed for PHP charges (12% PH VAT verified on the GMA account).
--
-- Run this in the Supabase SQL Editor AFTER supabase_expense_journal_categories.sql and
-- supabase_expense_journal_receipt_numbers.sql. Safe to re-run.

-- ---------------------------------------------------------------------------
-- Category

insert into public."ExpenseJournalCategories" ("Code", "Description", "CreatedBy")
values ('META-ADS', 'Meta Ads (Facebook/Instagram) wallet load', 'system')
on conflict ("Code") do nothing;

-- ---------------------------------------------------------------------------
-- MetaAdsBillingEvents: one row per funding / charge event from the activities log.

create table if not exists public."MetaAdsBillingEvents" (
    "EventKey" varchar(200) primary key,               -- fund:<account>:<epoch>:<centavos> / charge:<txn id>
    "AdAccountId" varchar(50) not null,
    "AdAccountName" varchar(200),
    "Kind" varchar(10) not null check ("Kind" in ('funding', 'charge')),
    "EventTimeUtc" timestamptz not null,
    "EventDate" date not null,                          -- Asia/Manila date (matches Meta's billing page)
    "Currency" varchar(10) not null default 'PHP',      -- ad account currency (PHP / EUR)
    "AmountOriginal" numeric(18, 2) not null,           -- in Currency. funding: loaded; charge: net of VAT
    "ExchangeRate" numeric(18, 6) not null default 1,   -- Currency -> PHP
    "RateSource" varchar(100),
    "AmountPhp" numeric(18, 2) not null,                -- AmountOriginal x ExchangeRate
    "VatInclusivePhp" numeric(18, 2),                   -- PHP charges only: net x 1.12 (Meta's "Paid")
    "PaymentMethod" varchar(50),                        -- funding only: GCash / Card
    "TransactionId" varchar(100),                       -- charge only
    "ExpenseJournalEntryID" uuid references public."ExpenseJournalEntries" ("EntryID") on delete set null,
    "ExtraData" jsonb,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."MetaAdsBillingEvents" enable row level security;
revoke all on public."MetaAdsBillingEvents" from anon, authenticated;

create index if not exists "IX_MetaAdsBillingEvents_EventDate" on public."MetaAdsBillingEvents" ("EventDate");

-- ---------------------------------------------------------------------------
-- MetaAdsAccountSnapshot: latest balance per ad account, overwritten each sync.

create table if not exists public."MetaAdsAccountSnapshot" (
    "AdAccountId" varchar(50) primary key,
    "AdAccountName" varchar(200),
    "Currency" varchar(10),
    -- All four in the account's own Currency (PHP or EUR), not converted.
    "AvailableBalance" numeric(18, 2),                  -- parsed from "Available Balance (PHP597.32)"
    "UnbilledSpend" numeric(18, 2),                     -- balance field: spent but not yet charged
    "AmountSpent" numeric(18, 2),                       -- lifetime
    "SpendCap" numeric(18, 2),
    "LastSyncAtUtc" timestamptz not null default timezone('utc', now()),
    "LastSyncResult" text
);

alter table public."MetaAdsAccountSnapshot" enable row level security;
revoke all on public."MetaAdsAccountSnapshot" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- service_log_meta_ads_events: idempotent batch insert. p_events is the raw activities "data" array
-- (only the two money event types are used; anything else is ignored), each non-PHP event carrying
-- php_rate + rate_source added by the Edge Function. A non-PHP event with no rate is skipped (not
-- inserted), so the next run - which re-pulls the last 3 days - retries it. Service role only.

drop function if exists public.service_log_meta_ads_events(text, text, jsonb, text);

create or replace function public.service_log_meta_ads_events(
  p_ad_account_id text,
  p_ad_account_name text,
  p_events jsonb,
  p_warehouse text
)
returns table(fundings_logged int, charges_logged int, duplicates int, skipped_no_rate int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ev jsonb;
  v_extra jsonb;
  v_type text;
  v_time timestamptz;
  v_date date;
  v_centavos numeric;
  v_amount numeric(18, 2);       -- in v_currency
  v_currency text;
  v_rate numeric(18, 6);
  v_rate_source text;
  v_php numeric(18, 2);
  v_key text;
  v_method text;
  v_txn text;
  v_entry_id uuid;
  v_exp_no text;
  v_fund int := 0;
  v_charge int := 0;
  v_dup int := 0;
  v_norate int := 0;
  v_rows int;
begin
  -- One sync at a time per account, so an overlapping manual run + cron can't double-insert.
  perform pg_advisory_xact_lock(hashtext('meta_ads_sync:' || p_ad_account_id));

  for v_ev in select * from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) loop
    v_type := v_ev->>'event_type';
    continue when v_type not in ('funding_event_successful', 'ad_account_billing_charge');

    -- extra_data arrives as a JSON-encoded string.
    begin
      v_extra := case jsonb_typeof(v_ev->'extra_data')
                   when 'string' then (v_ev->>'extra_data')::jsonb
                   else v_ev->'extra_data' end;
    exception when others then
      continue;
    end;

    v_time := (v_ev->>'event_time')::timestamptz;
    v_date := (v_time at time zone 'Asia/Manila')::date;
    v_currency := upper(coalesce(nullif(v_extra->>'currency', ''), 'PHP'));
    if v_currency = 'PHP' then
      v_rate := 1;
      v_rate_source := null;
    else
      v_rate := nullif(v_ev->>'php_rate', '')::numeric;
      v_rate_source := left(v_ev->>'rate_source', 100);
      if v_rate is null or v_rate <= 0 then
        v_norate := v_norate + 1;
        continue;
      end if;
    end if;

    if v_type = 'funding_event_successful' then
      v_centavos := nullif(v_extra->>'amount', '')::numeric;
      continue when v_centavos is null or v_centavos <= 0;
      v_amount := round(v_centavos / 100.0, 2);
      v_php := round(v_amount * v_rate, 2);
      v_method := case when coalesce(v_extra->>'network_id', '') in ('', '0') then 'Card'
                       else v_extra->>'network_id' end;
      v_key := format('fund:%s:%s:%s', p_ad_account_id, extract(epoch from v_time)::bigint, v_centavos::bigint);

      if exists (select 1 from public."MetaAdsBillingEvents" where "EventKey" = v_key) then
        v_dup := v_dup + 1;
        continue;
      end if;

      v_exp_no := 'EXP-' || lpad(nextval('public."ExpenseJournalReceiptNoSeq"')::text, 9, '0');

      insert into public."ExpenseJournalEntries"
        ("ReceiptNo", "EntryDate", "ExpenseCategory", "Description", "Amount", "Warehouse", "CreatedBy")
      values (
        v_exp_no,
        v_date,
        'META-ADS - Meta Ads (Facebook/Instagram) wallet load',
        left(format('Meta Ads wallet load via %s%s - %s (act_%s)', v_method,
                    case when v_currency = 'PHP' then ''
                         else format(' - %s %s @ %s', v_currency, to_char(v_amount, 'FM999,990.00'), to_char(v_rate, 'FM990.0000')) end,
                    coalesce(nullif(p_ad_account_name, ''), 'ad account'), p_ad_account_id), 500),
        v_php,
        nullif(trim(coalesce(p_warehouse, '')), ''),
        'auto-meta-ads-sync'
      )
      returning "EntryID" into v_entry_id;

      insert into public."MetaAdsBillingEvents"
        ("EventKey", "AdAccountId", "AdAccountName", "Kind", "EventTimeUtc", "EventDate", "Currency",
         "AmountOriginal", "ExchangeRate", "RateSource", "AmountPhp", "PaymentMethod", "ExpenseJournalEntryID", "ExtraData")
      values
        (v_key, p_ad_account_id, p_ad_account_name, 'funding', v_time, v_date, v_currency,
         v_amount, v_rate, v_rate_source, v_php, v_method, v_entry_id, v_extra);

      v_fund := v_fund + 1;

    else -- ad_account_billing_charge
      v_centavos := nullif(v_extra->>'new_value', '')::numeric;
      continue when v_centavos is null or v_centavos <= 0;
      v_amount := round(v_centavos / 100.0, 2);
      v_txn := nullif(v_extra->>'transaction_id', '');
      v_key := coalesce('charge:' || v_txn,
                        format('charge:%s:%s:%s', p_ad_account_id, extract(epoch from v_time)::bigint, v_centavos::bigint));

      insert into public."MetaAdsBillingEvents"
        ("EventKey", "AdAccountId", "AdAccountName", "Kind", "EventTimeUtc", "EventDate", "Currency",
         "AmountOriginal", "ExchangeRate", "RateSource", "AmountPhp", "VatInclusivePhp", "TransactionId", "ExtraData")
      values
        (v_key, p_ad_account_id, p_ad_account_name, 'charge', v_time, v_date, v_currency,
         v_amount, v_rate, v_rate_source, round(v_amount * v_rate, 2),
         case when v_currency = 'PHP' then round(v_amount * 1.12, 2) end, v_txn, v_extra)
      on conflict ("EventKey") do nothing;

      get diagnostics v_rows = row_count;
      if v_rows > 0 then v_charge := v_charge + 1; else v_dup := v_dup + 1; end if;
    end if;
  end loop;

  return query select v_fund, v_charge, v_dup, v_norate;
end;
$$;

revoke all on function public.service_log_meta_ads_events(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.service_log_meta_ads_events(text, text, jsonb, text) to service_role;

-- ---------------------------------------------------------------------------
-- service_set_meta_ads_snapshot now lives in supabase_meta_ads_page.sql (it gained a p_store
-- parameter there). Only the original 8-argument version is dropped here, so re-running this file
-- never leaves an old overload behind.

drop function if exists public.service_set_meta_ads_snapshot(text, text, text, numeric, numeric, numeric, numeric, text);

-- ---------------------------------------------------------------------------
-- Daily cron: 07:00 Manila (23:00 UTC), after Meta's nightly ~06:22 Manila billing charge.
-- Pulls the last 3 days each time; duplicates are skipped, so overlap is harmless.

create or replace function public.cron_meta_ads_sync()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  -- Public/"publishable" anon key - same value already committed in docs/js/config.js and
  -- supabase_chatbot_followups.sql.
  v_anon_key text := 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz';
  v_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/meta-ads-sync';
begin
  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '25000');
    perform extensions.http((
      'POST',
      v_url,
      array[
        extensions.http_header('Authorization', 'Bearer ' || v_anon_key),
        extensions.http_header('apikey', v_anon_key)
      ],
      'application/json',
      '{}'
    )::extensions.http_request);
  exception when others then
    null; -- best-effort; tomorrow's run re-pulls the last 3 days anyway
  end;
end;
$$;

select cron.unschedule('meta-ads-sync') where exists (select 1 from cron.job where jobname = 'meta-ads-sync');

select cron.schedule(
  'meta-ads-sync',
  '0 23 * * *',
  $$select public.cron_meta_ads_sync();$$
);
