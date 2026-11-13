-- Claude spend tracking - per direct request ("I'm topping up every time, I want to log it to our
-- system to track my expense" + "if possible peso and dollar" + "yes I want [usage tracking] as well").
--
-- Two halves:
--
-- 1. RECEIPTS -> EXPENSE JOURNAL (automatic). Anthropic has no API for credit purchases / receipts,
--    so a Google Apps Script in the owner's Gmail (tools/gmail-claude-receipts.gs) reads each
--    Anthropic receipt email and POSTs it to the claude-receipt-log Edge Function, which looks up the
--    day's USD->PHP rate and calls service_log_claude_receipt below. That writes:
--      - one ClaudeReceipts row (USD subtotal / VAT / total, rate, PHP amount) - keyed on Anthropic's
--        own receipt number, so the same email can never be logged twice, and
--      - one normal ExpenseJournalEntries row (PHP amount, EXP- receipt no) so it shows up on the
--        Expense Journal, Posted Expenses, Dashboard and G/L exactly like a manual entry.
--    API credit top-ups and the Claude Pro/Max subscription get separate categories.
--
-- 2. USAGE (what the bot actually spends). Every Claude call made by an Edge Function now writes one
--    AIUsageLog row with its token counts (supabase/functions/_shared/ai-usage.ts). Cost is computed
--    at read time from AIModelPricing, so a price change only needs that table updated. The AI Spend
--    page (docs/ai-spend.html) shows usage by day / feature / model plus an ESTIMATED remaining
--    credit balance = the balance you typed in once (AICreditBalance) + API credit top-ups since then
--    - usage since then.
--
-- Run this in the Supabase SQL Editor AFTER supabase_expense_journal_categories.sql and
-- supabase_expense_journal_receipt_numbers.sql. Safe to re-run.

-- ---------------------------------------------------------------------------
-- Categories (Code - Description format, same as the Manage Categories panel)

insert into public."ExpenseJournalCategories" ("Code", "Description", "CreatedBy")
values ('AI-CLAUDE-API', 'Claude API Credits (AI Bot)', 'system'),
       ('AI-CLAUDE-SUB', 'Claude Subscription', 'system')
on conflict ("Code") do nothing;

-- ---------------------------------------------------------------------------
-- ClaudeReceipts: one row per Anthropic receipt email.

create table if not exists public."ClaudeReceipts" (
    "ReceiptNumber" varchar(50) primary key,          -- Anthropic's, e.g. 2866-2191-8770
    "InvoiceNumber" varchar(50),
    "DatePaid" date not null,
    "Kind" varchar(20) not null check ("Kind" in ('api_credits', 'subscription')),
    "ItemDescription" varchar(300),
    "SubtotalUsd" numeric(18, 2),                      -- excl. VAT = credits actually added
    "TaxUsd" numeric(18, 2),
    "TotalUsd" numeric(18, 2) not null check ("TotalUsd" > 0),
    "ExchangeRate" numeric(18, 6) not null check ("ExchangeRate" > 0),
    "RateSource" varchar(100),
    "AmountPhp" numeric(18, 2) not null,
    "ExpenseJournalEntryID" uuid references public."ExpenseJournalEntries" ("EntryID") on delete set null,
    "GmailMessageId" varchar(100),
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."ClaudeReceipts" enable row level security;
revoke all on public."ClaudeReceipts" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- AIUsageLog: one row per Claude API call made by an Edge Function. Written with the service role
-- (bypasses RLS); never read directly by the browser.

create table if not exists public."AIUsageLog" (
    "Id" bigserial primary key,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now()),
    "Source" varchar(60) not null,                     -- Edge Function / feature name
    "Model" varchar(80),
    "InputTokens" integer not null default 0,
    "OutputTokens" integer not null default 0,
    "CacheWriteTokens" integer not null default 0,
    "CacheReadTokens" integer not null default 0,
    "WebSearchRequests" integer not null default 0
);

alter table public."AIUsageLog" enable row level security;
revoke all on public."AIUsageLog" from anon, authenticated;
create index if not exists "IX_AIUsageLog_CreatedAtUtc" on public."AIUsageLog" ("CreatedAtUtc");

-- ---------------------------------------------------------------------------
-- AIModelPricing: USD per million tokens. Matched against the model a response reports by exact
-- name or prefix (claude-haiku-4-5 matches claude-haiku-4-5-20251001). Update when Anthropic
-- changes prices - the AI Spend page shows these so a stale price is easy to spot.

create table if not exists public."AIModelPricing" (
    "Model" varchar(80) primary key,
    "InputPerMTok" numeric(12, 4) not null,
    "OutputPerMTok" numeric(12, 4) not null,
    "CacheWritePerMTok" numeric(12, 4) not null,
    "CacheReadPerMTok" numeric(12, 4) not null,
    "UpdatedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."AIModelPricing" enable row level security;
revoke all on public."AIModelPricing" from anon, authenticated;

insert into public."AIModelPricing" ("Model", "InputPerMTok", "OutputPerMTok", "CacheWritePerMTok", "CacheReadPerMTok") values
  ('claude-fable-5-2',  8.00, 40.00, 10.00,  0.20),
  ('claude-opus-5-5',   4.00, 20.00,  5.00,  0.20),
  ('claude-opus-5',     5.00, 25.00,  6.25,  0.50),
  ('claude-opus-4-8',   5.00, 25.00,  6.25,  0.50),
  ('claude-sonnet-5-5', 2.00, 10.00,  2.50,  0.10),
  ('claude-sonnet-5',   2.00, 10.00,  2.50,  0.20),
  ('claude-sonnet-4-6', 3.00, 15.00,  3.75,  0.30),
  ('claude-haiku-5-5',  0.10,  0.50,  0.125, 0.01),
  ('claude-haiku-4-5',  1.00,  5.00,  1.25,  0.10)
on conflict ("Model") do nothing;

-- Web search is billed per request on top of tokens ($10 per 1,000 searches).

-- ---------------------------------------------------------------------------
-- AICreditBalance: single row - the Console balance as typed in on the AI Spend page, and when.

create table if not exists public."AICreditBalance" (
    "Id" integer primary key default 1 check ("Id" = 1),
    "BalanceUsd" numeric(18, 2) not null,
    "AsOfUtc" timestamptz not null,
    "SetBy" varchar(100) not null
);

alter table public."AICreditBalance" enable row level security;
revoke all on public."AICreditBalance" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- _ai_usage_cost_usd: cost of one usage row. Longest matching price row wins; an unknown model
-- costs 0 (and shows up as "no price" on the page).

create or replace function public._ai_usage_cost_usd(
  p_model text, p_input int, p_output int, p_cache_write int, p_cache_read int, p_web_search int
)
returns numeric
language sql
stable
set search_path = public
as $$
  select coalesce((
    select (coalesce(p_input, 0) * p."InputPerMTok"
          + coalesce(p_output, 0) * p."OutputPerMTok"
          + coalesce(p_cache_write, 0) * p."CacheWritePerMTok"
          + coalesce(p_cache_read, 0) * p."CacheReadPerMTok") / 1000000.0
    from public."AIModelPricing" p
    where p_model = p."Model" or p_model like p."Model" || '-%'
    order by length(p."Model") desc
    limit 1
  ), 0) + coalesce(p_web_search, 0) * 0.01;
$$;

revoke all on function public._ai_usage_cost_usd(text, int, int, int, int, int) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- service_log_claude_receipt: called ONLY by the claude-receipt-log Edge Function (service role).
-- Returns status 'logged' or 'duplicate'.

drop function if exists public.service_log_claude_receipt(text, text, date, text, text, numeric, numeric, numeric, numeric, text, text, text);

create or replace function public.service_log_claude_receipt(
  p_receipt_number text,
  p_invoice_number text,
  p_date_paid date,
  p_kind text,
  p_item_description text,
  p_subtotal_usd numeric,
  p_tax_usd numeric,
  p_total_usd numeric,
  p_exchange_rate numeric,
  p_rate_source text,
  p_warehouse text,
  p_gmail_message_id text
)
returns table(status text, receipt_no text, amount_php numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_receipt text := trim(coalesce(p_receipt_number, ''));
  v_amount_php numeric(18, 2) := round(p_total_usd * p_exchange_rate, 2);
  v_category text;
  v_label text;
  v_entry_id uuid;
  v_exp_no text;
begin
  if v_receipt = '' then raise exception 'Receipt number is required.'; end if;
  if p_kind not in ('api_credits', 'subscription') then raise exception 'Unknown receipt kind %.', p_kind; end if;
  if p_total_usd is null or p_total_usd <= 0 then raise exception 'Total must be greater than zero.'; end if;
  if p_exchange_rate is null or p_exchange_rate <= 0 then raise exception 'Exchange rate is required.'; end if;

  -- Lock on the receipt number so two simultaneous posts of the same email can't both insert.
  perform pg_advisory_xact_lock(hashtext('claude_receipt:' || v_receipt));

  if exists (select 1 from public."ClaudeReceipts" where "ReceiptNumber" = v_receipt) then
    return query
      select 'duplicate'::text, j."ReceiptNo"::text, r."AmountPhp"
      from public."ClaudeReceipts" r
      left join public."ExpenseJournalEntries" j on j."EntryID" = r."ExpenseJournalEntryID"
      where r."ReceiptNumber" = v_receipt;
    return;
  end if;

  if p_kind = 'api_credits' then
    v_category := 'AI-CLAUDE-API - Claude API Credits (AI Bot)';
    v_label := 'Claude API credits';
  else
    v_category := 'AI-CLAUDE-SUB - Claude Subscription';
    v_label := coalesce(nullif(trim(coalesce(p_item_description, '')), ''), 'Claude subscription');
  end if;

  v_exp_no := 'EXP-' || lpad(nextval('public."ExpenseJournalReceiptNoSeq"')::text, 9, '0');

  insert into public."ExpenseJournalEntries"
    ("ReceiptNo", "EntryDate", "ExpenseCategory", "Description", "Amount", "Warehouse", "CreatedBy")
  values (
    v_exp_no,
    p_date_paid,
    v_category,
    left(format('%s - USD %s @ %s - Anthropic receipt %s', v_label,
                to_char(p_total_usd, 'FM999,990.00'), to_char(p_exchange_rate, 'FM990.0000'), v_receipt), 500),
    v_amount_php,
    nullif(trim(coalesce(p_warehouse, '')), ''),
    'auto-claude-receipt'
  )
  returning "EntryID" into v_entry_id;

  insert into public."ClaudeReceipts"
    ("ReceiptNumber", "InvoiceNumber", "DatePaid", "Kind", "ItemDescription", "SubtotalUsd", "TaxUsd",
     "TotalUsd", "ExchangeRate", "RateSource", "AmountPhp", "ExpenseJournalEntryID", "GmailMessageId")
  values
    (v_receipt, nullif(trim(coalesce(p_invoice_number, '')), ''), p_date_paid, p_kind,
     left(p_item_description, 300), p_subtotal_usd, p_tax_usd, p_total_usd, p_exchange_rate,
     left(p_rate_source, 100), v_amount_php, v_entry_id, left(p_gmail_message_id, 100));

  return query select 'logged'::text, v_exp_no, v_amount_php;
end;
$$;

revoke all on function public.service_log_claude_receipt(text, text, date, text, text, numeric, numeric, numeric, numeric, text, text, text) from public, anon, authenticated;
grant execute on function public.service_log_claude_receipt(text, text, date, text, text, numeric, numeric, numeric, numeric, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- admin_get_ai_spend: everything the AI Spend page shows, as one jsonb (dates are Manila dates,
-- inclusive).

drop function if exists public.admin_get_ai_spend(text, text, date, date);

create or replace function public.admin_get_ai_spend(
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
  v_from_utc timestamptz := (p_from::timestamp at time zone 'Asia/Manila');
  v_to_utc timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Manila');
  v_result jsonb;
  v_anchor_usd numeric;
  v_anchor_at timestamptz;
  v_anchor_by text;
  v_topups_since numeric := 0;
  v_usage_since numeric := 0;
  v_usage_7d numeric := 0;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  with u as (
    select l.*,
           (l."CreatedAtUtc" at time zone 'Asia/Manila')::date as d,
           public._ai_usage_cost_usd(l."Model", l."InputTokens", l."OutputTokens", l."CacheWriteTokens", l."CacheReadTokens", l."WebSearchRequests") as cost
    from public."AIUsageLog" l
    where l."CreatedAtUtc" >= v_from_utc and l."CreatedAtUtc" < v_to_utc
  )
  select jsonb_build_object(
    'totals', (select jsonb_build_object(
                  'requests', count(*),
                  'cost_usd', coalesce(sum(cost), 0),
                  'input_tokens', coalesce(sum("InputTokens" + "CacheWriteTokens" + "CacheReadTokens"), 0),
                  'output_tokens', coalesce(sum("OutputTokens"), 0)) from u),
    'by_day', coalesce((select jsonb_agg(x order by x->>'day') from (
                  select jsonb_build_object('day', d, 'requests', count(*), 'cost_usd', sum(cost)) x
                  from u group by d) s), '[]'::jsonb),
    'by_source', coalesce((select jsonb_agg(x order by (x->>'cost_usd')::numeric desc) from (
                  select jsonb_build_object('source', "Source", 'requests', count(*), 'cost_usd', sum(cost)) x
                  from u group by "Source") s), '[]'::jsonb),
    'by_model', coalesce((select jsonb_agg(x order by (x->>'cost_usd')::numeric desc) from (
                  select jsonb_build_object('model', u."Model", 'requests', count(*), 'cost_usd', sum(cost),
                         'priced', exists (select 1 from public."AIModelPricing" p
                                           where u."Model" = p."Model" or u."Model" like p."Model" || '-%')) x
                  from u group by u."Model") s), '[]'::jsonb),
    'receipts', coalesce((select jsonb_agg(jsonb_build_object(
                  'receipt_number', r."ReceiptNumber", 'date_paid', r."DatePaid", 'kind', r."Kind",
                  'item', r."ItemDescription", 'subtotal_usd', r."SubtotalUsd", 'tax_usd', r."TaxUsd",
                  'total_usd', r."TotalUsd", 'exchange_rate', r."ExchangeRate", 'amount_php', r."AmountPhp",
                  'expense_receipt_no', j."ReceiptNo") order by r."DatePaid" desc, r."CreatedAtUtc" desc)
                  from public."ClaudeReceipts" r
                  left join public."ExpenseJournalEntries" j on j."EntryID" = r."ExpenseJournalEntryID"
                  where r."DatePaid" between p_from and p_to), '[]'::jsonb),
    'pricing', coalesce((select jsonb_agg(jsonb_build_object(
                  'model', "Model", 'input', "InputPerMTok", 'output', "OutputPerMTok",
                  'cache_write', "CacheWritePerMTok", 'cache_read', "CacheReadPerMTok") order by "Model")
                  from public."AIModelPricing"), '[]'::jsonb)
  ) into v_result;

  -- Estimated balance: anchor + API credit top-ups (excl. VAT) since the anchor - usage since the anchor.
  select "BalanceUsd", "AsOfUtc", "SetBy" into v_anchor_usd, v_anchor_at, v_anchor_by
  from public."AICreditBalance" where "Id" = 1;
  if v_anchor_at is not null then
    select coalesce(sum(coalesce("SubtotalUsd", "TotalUsd")), 0) into v_topups_since
    from public."ClaudeReceipts"
    where "Kind" = 'api_credits' and "CreatedAtUtc" > v_anchor_at;

    select coalesce(sum(public._ai_usage_cost_usd("Model", "InputTokens", "OutputTokens", "CacheWriteTokens", "CacheReadTokens", "WebSearchRequests")), 0)
    into v_usage_since
    from public."AIUsageLog" where "CreatedAtUtc" > v_anchor_at;
  end if;

  select coalesce(sum(public._ai_usage_cost_usd("Model", "InputTokens", "OutputTokens", "CacheWriteTokens", "CacheReadTokens", "WebSearchRequests")), 0)
  into v_usage_7d
  from public."AIUsageLog" where "CreatedAtUtc" > now() - interval '7 days';

  return v_result || jsonb_build_object('balance', jsonb_build_object(
    'anchor_usd', v_anchor_usd,
    'anchor_at', v_anchor_at,
    'anchor_by', v_anchor_by,
    'topups_since_usd', v_topups_since,
    'usage_since_usd', v_usage_since,
    'estimated_usd', case when v_anchor_usd is null then null
                          else v_anchor_usd + v_topups_since - v_usage_since end,
    'avg_daily_usd_7d', round(v_usage_7d / 7.0, 4)
  ));
end;
$$;

grant execute on function public.admin_get_ai_spend(text, text, date, date) to anon;

-- ---------------------------------------------------------------------------
-- admin_set_ai_credit_balance: "my Console balance right now is $X" - resets the estimate's anchor.

drop function if exists public.admin_set_ai_credit_balance(text, text, numeric);

create or replace function public.admin_set_ai_credit_balance(p_admin_username text, p_admin_password text, p_balance_usd numeric)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_balance_usd is null or p_balance_usd < 0 then
    raise exception 'Balance must be zero or more.';
  end if;

  insert into public."AICreditBalance" ("Id", "BalanceUsd", "AsOfUtc", "SetBy")
  values (1, p_balance_usd, timezone('utc', now()), p_admin_username)
  on conflict ("Id") do update
    set "BalanceUsd" = excluded."BalanceUsd", "AsOfUtc" = excluded."AsOfUtc", "SetBy" = excluded."SetBy";
end;
$$;

grant execute on function public.admin_set_ai_credit_balance(text, text, numeric) to anon;

-- ---------------------------------------------------------------------------
-- admin_set_claude_receipt_php: the bank charged a different peso amount than the day's rate gave -
-- fix the PHP amount on both the receipt and its Expense Journal entry.

drop function if exists public.admin_set_claude_receipt_php(text, text, text, numeric);

create or replace function public.admin_set_claude_receipt_php(
  p_admin_username text, p_admin_password text, p_receipt_number text, p_amount_php numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry_id uuid;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_amount_php is null or p_amount_php <= 0 then
    raise exception 'Peso amount must be greater than zero.';
  end if;

  update public."ClaudeReceipts"
  set "AmountPhp" = round(p_amount_php, 2),
      "ExchangeRate" = round(p_amount_php / "TotalUsd", 6),
      "RateSource" = 'manual (bank amount)'
  where "ReceiptNumber" = p_receipt_number
  returning "ExpenseJournalEntryID" into v_entry_id;

  if not found then
    raise exception 'Receipt % not found.', p_receipt_number;
  end if;

  if v_entry_id is not null then
    update public."ExpenseJournalEntries"
    set "Amount" = round(p_amount_php, 2),
        "Description" = left(regexp_replace(coalesce("Description", ''), ' @ [0-9.]+', ' @ bank ') , 500)
    where "EntryID" = v_entry_id;
  end if;
end;
$$;

grant execute on function public.admin_set_claude_receipt_php(text, text, text, numeric) to anon;

-- ---------------------------------------------------------------------------
-- admin_upsert_ai_model_pricing: update a model's per-million-token prices from the page.

drop function if exists public.admin_upsert_ai_model_pricing(text, text, text, numeric, numeric, numeric, numeric);

create or replace function public.admin_upsert_ai_model_pricing(
  p_admin_username text, p_admin_password text, p_model text,
  p_input numeric, p_output numeric, p_cache_write numeric, p_cache_read numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if trim(coalesce(p_model, '')) = '' then raise exception 'Model is required.'; end if;
  if least(p_input, p_output, p_cache_write, p_cache_read) is null or least(p_input, p_output, p_cache_write, p_cache_read) < 0 then
    raise exception 'All four prices are required and cannot be negative.';
  end if;

  insert into public."AIModelPricing" ("Model", "InputPerMTok", "OutputPerMTok", "CacheWritePerMTok", "CacheReadPerMTok", "UpdatedAtUtc")
  values (trim(p_model), p_input, p_output, p_cache_write, p_cache_read, timezone('utc', now()))
  on conflict ("Model") do update set
    "InputPerMTok" = excluded."InputPerMTok", "OutputPerMTok" = excluded."OutputPerMTok",
    "CacheWritePerMTok" = excluded."CacheWritePerMTok", "CacheReadPerMTok" = excluded."CacheReadPerMTok",
    "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

grant execute on function public.admin_upsert_ai_model_pricing(text, text, text, numeric, numeric, numeric, numeric) to anon;
