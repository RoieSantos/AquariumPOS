-- General Ledger - per direct request: "i want to build General ledger entries this will see all
-- my purchase / expense so I can track everything on my financials .. same on how we build it in
-- business central", together with the PO -> Vendor Bill link.
--
-- Until now the portal had no ledger of any kind outside payroll: the dashboard's Purchase and
-- Expense cards each queried their own source table directly, Vendor Bills were keyed in by hand
-- with nothing linking them to the Purchase Orders they were paying for, and there was no single
-- place where a purchase and an expense could be seen side by side. This adds that place.
--
-- MODELLED ON BUSINESS CENTRAL, deliberately:
--   * A chart of accounts (GLAccounts) with an account type per account.
--   * G/L Entries that are APPEND-ONLY. Nothing is ever updated or deleted - a mistake is
--     corrected by posting a reversing entry, so the ledger stays an auditable history rather
--     than a mutable current state. This is why voiding a bill posts an opposite entry instead of
--     removing the original.
--   * Every posting is BALANCED and grouped by a TransactionNo, so debits and credits always net
--     to zero within one transaction. _gl_post below refuses to write an unbalanced set, which
--     makes it impossible for the books to drift no matter which caller is posting.
--   * Signed Amount (debit positive, credit negative) with DebitAmount/CreditAmount derived from
--     it, exactly as BC's G/L Entry table does.
--
-- WHAT POSTS HERE
--   Purchase Order posted  -> Dr Inventory,        Cr Accounts Payable   (via an auto Vendor Bill)
--   Vendor Bill created    -> Dr <bill account>,   Cr Accounts Payable
--   Vendor Bill voided     -> the reverse of the above
--   Vendor Payment created -> Dr Accounts Payable, Cr Cash or Digital    (by payment Method)
--   Vendor Payment voided  -> the reverse of the above
--   Expense posted to G/L  -> Dr mapped expense account, Cr Cash          (manual batch run)
--
-- Sales are deliberately NOT posted yet: online/walk-in orders sync from Pancake continuously and
-- have no posting step to hook, so income would need the same "post to G/L" batch treatment the
-- expenses get here. Left out rather than half-built - the accounts (4000 Sales) are seeded ready.

-- ============================================================================
-- 1. Chart of accounts
-- ============================================================================

create table if not exists public."GLAccounts" (
    "AccountNo" varchar(20) primary key,
    "Name" varchar(200) not null,
    -- BC's five account types. Drives the sign convention when reading balances: Asset/Expense
    -- accounts are debit-natured (a positive balance is a debit), Liability/Equity/Income are
    -- credit-natured.
    "AccountType" varchar(20) not null check ("AccountType" in ('Asset', 'Liability', 'Equity', 'Income', 'Expense')),
    -- BC's "Direct Posting": a control account like Accounts Payable should only ever be moved by
    -- a document (a bill, a payment), never by someone hand-keying a journal into it.
    "DirectPosting" boolean not null default true,
    "IsActive" boolean not null default true,
    "CreatedAtUtc" timestamptz not null default now()
);

alter table public."GLAccounts" enable row level security;
revoke all on public."GLAccounts" from anon, authenticated;

-- Starter chart, editable afterwards through G/L Setup. Idempotent "insert where not exists" per
-- account, the same idiom the NoSeries seeds use - so re-running this file never disturbs an
-- account whose name or number has since been changed by the user.
insert into public."GLAccounts" ("AccountNo", "Name", "AccountType", "DirectPosting")
select * from (values
  ('1000', 'Cash on Hand',              'Asset',     true),
  ('1010', 'Digital / Bank',            'Asset',     true),
  ('1300', 'Inventory',                 'Asset',     false),
  ('2000', 'Accounts Payable',          'Liability', false),
  ('3000', 'Owner''s Equity',           'Equity',    true),
  ('4000', 'Sales',                     'Income',    true),
  ('5000', 'Cost of Goods Sold',        'Expense',   true),
  ('6000', 'Operating Expenses',        'Expense',   true),
  ('6100', 'Utilities',                 'Expense',   true),
  ('6200', 'Rent',                      'Expense',   true),
  ('6300', 'Salaries and Wages',        'Expense',   true),
  ('6400', 'Supplies',                  'Expense',   true),
  ('6500', 'Repairs and Maintenance',   'Expense',   true),
  ('6600', 'Transportation and Fuel',   'Expense',   true),
  ('6900', 'Miscellaneous Expense',     'Expense',   true)
) as seed("AccountNo", "Name", "AccountType", "DirectPosting")
where not exists (select 1 from public."GLAccounts" a where a."AccountNo" = seed."AccountNo");

-- ============================================================================
-- 2. G/L Entries
-- ============================================================================

-- Groups the two-or-more entries that make up one balanced posting, so a transaction can be shown
-- and reversed as a unit.
create sequence if not exists public.gl_transaction_no_seq as bigint;

create table if not exists public."GLEntries" (
    "EntryNo" bigint generated always as identity primary key,
    "TransactionNo" bigint not null,
    "PostingDate" date not null,
    "AccountNo" varchar(20) not null references public."GLAccounts" ("AccountNo"),
    "Description" varchar(500),
    -- Signed: debit positive, credit negative. One column rather than two independent ones means
    -- a transaction can be balance-checked with a plain sum, and can never hold a debit AND a
    -- credit on the same line.
    "Amount" numeric(18, 2) not null,
    "DebitAmount" numeric(18, 2) generated always as (case when "Amount" > 0 then "Amount" else 0 end) stored,
    "CreditAmount" numeric(18, 2) generated always as (case when "Amount" < 0 then -"Amount" else 0 end) stored,
    -- What produced this entry, for drill-back and to stop the same document posting twice.
    "DocumentType" varchar(30) not null,
    "DocumentNo" varchar(50),
    "SourceType" varchar(20),
    "SourceNo" varchar(50),
    "PostedBy" varchar(100),
    "PostedAtUtc" timestamptz not null default now()
);

alter table public."GLEntries" enable row level security;
revoke all on public."GLEntries" from anon, authenticated;

create index if not exists "IX_GLEntries_PostingDate" on public."GLEntries" ("PostingDate");
create index if not exists "IX_GLEntries_AccountNo" on public."GLEntries" ("AccountNo");
create index if not exists "IX_GLEntries_TransactionNo" on public."GLEntries" ("TransactionNo");
create index if not exists "IX_GLEntries_Document" on public."GLEntries" ("DocumentType", "DocumentNo");

comment on table public."GLEntries" is 'Append-only general ledger. Never UPDATE or DELETE a row here - correct a mistake by posting a reversing transaction, so the history stays auditable.';

-- ============================================================================
-- 3. Posting setup - which account each kind of posting uses
-- ============================================================================

-- Single-row settings table. The Id check constraint is the standard one-row idiom: the column can
-- only ever hold true, and it is the primary key, so a second row is impossible.
create table if not exists public."GLSetup" (
    "Id" boolean primary key default true check ("Id"),
    "InventoryAccountNo" varchar(20) references public."GLAccounts" ("AccountNo"),
    "PayableAccountNo" varchar(20) references public."GLAccounts" ("AccountNo"),
    "CashAccountNo" varchar(20) references public."GLAccounts" ("AccountNo"),
    "DigitalAccountNo" varchar(20) references public."GLAccounts" ("AccountNo"),
    "DefaultExpenseAccountNo" varchar(20) references public."GLAccounts" ("AccountNo"),
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

alter table public."GLSetup" enable row level security;
revoke all on public."GLSetup" from anon, authenticated;

insert into public."GLSetup" ("Id", "InventoryAccountNo", "PayableAccountNo", "CashAccountNo", "DigitalAccountNo", "DefaultExpenseAccountNo")
select true, '1300', '2000', '1000', '1010', '6900'
where not exists (select 1 from public."GLSetup");

-- ExpenseCategory is free text typed on the desktop POS with no setup table behind it, so it
-- cannot be a foreign key. This maps whatever categories actually turn up to real accounts;
-- anything unmapped falls back to GLSetup.DefaultExpenseAccountNo rather than blocking the post.
create table if not exists public."GLExpenseCategoryMap" (
    "ExpenseCategory" varchar(200) primary key,
    "AccountNo" varchar(20) not null references public."GLAccounts" ("AccountNo"),
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

alter table public."GLExpenseCategoryMap" enable row level security;
revoke all on public."GLExpenseCategoryMap" from anon, authenticated;

-- ============================================================================
-- 4. The posting engine
-- ============================================================================

-- The ONLY way anything reaches GLEntries. Every caller hands it a set of lines that must balance;
-- an unbalanced set raises rather than writing, so no combination of callers can put the ledger
-- out of balance.
--
-- p_lines is [{"account_no": "1300", "amount": 1500.00, "description": "..."}] with amount signed
-- (debit positive, credit negative). Returns the TransactionNo the entries were written under.
create or replace function public._gl_post(
  p_posting_date date,
  p_document_type text,
  p_document_no text,
  p_description text,
  p_source_type text,
  p_source_no text,
  p_lines jsonb,
  p_posted_by text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_transaction_no bigint;
  v_line jsonb;
  v_account_no text;
  v_amount numeric;
  v_total numeric := 0;
  v_line_count int := 0;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) < 2 then
    raise exception 'A G/L transaction needs at least two lines (a debit and a credit).';
  end if;

  -- First pass validates everything, so a bad account on the last line cannot leave half a
  -- transaction written.
  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_account_no := nullif(trim(coalesce(v_line ->> 'account_no', '')), '');
    v_amount := round(coalesce((v_line ->> 'amount')::numeric, 0), 2);

    if v_account_no is null then
      raise exception 'Every G/L line needs an account.';
    end if;

    if not exists (select 1 from public."GLAccounts" where "AccountNo" = v_account_no and "IsActive") then
      raise exception 'G/L account "%" does not exist or is not active. Check G/L Setup.', v_account_no;
    end if;

    if v_amount = 0 then
      raise exception 'G/L account "%" was given a zero amount - nothing to post.', v_account_no;
    end if;

    v_total := v_total + v_amount;
    v_line_count := v_line_count + 1;
  end loop;

  -- Compared against zero exactly: every amount was rounded to 2dp above, so a balanced set sums
  -- to exactly zero and no tolerance is needed or wanted.
  if v_total <> 0 then
    raise exception 'G/L transaction does not balance - debits minus credits = %. Nothing was posted.', v_total;
  end if;

  v_transaction_no := nextval('public.gl_transaction_no_seq');

  insert into public."GLEntries" ("TransactionNo", "PostingDate", "AccountNo", "Description", "Amount", "DocumentType", "DocumentNo", "SourceType", "SourceNo", "PostedBy")
  select
    v_transaction_no,
    p_posting_date,
    trim(line ->> 'account_no'),
    coalesce(nullif(trim(coalesce(line ->> 'description', '')), ''), p_description),
    round((line ->> 'amount')::numeric, 2),
    p_document_type,
    p_document_no,
    p_source_type,
    p_source_no,
    p_posted_by
  from jsonb_array_elements(p_lines) as line;

  return v_transaction_no;
end;
$$;

-- Reverses an existing transaction by posting its mirror image. Used by the void paths - the
-- original entries are left exactly as they were, which is what makes the ledger auditable.
create or replace function public._gl_reverse(
  p_transaction_no bigint,
  p_posting_date date,
  p_description text,
  p_posted_by text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lines jsonb;
  v_document_type text;
  v_document_no text;
  v_source_type text;
  v_source_no text;
begin
  select jsonb_agg(jsonb_build_object('account_no', "AccountNo", 'amount', -"Amount", 'description', p_description)),
         min("DocumentType"), min("DocumentNo"), min("SourceType"), min("SourceNo")
    into v_lines, v_document_type, v_document_no, v_source_type, v_source_no
  from public."GLEntries"
  where "TransactionNo" = p_transaction_no;

  if v_lines is null then
    raise exception 'G/L transaction % not found - nothing to reverse.', p_transaction_no;
  end if;

  return public._gl_post(
    p_posting_date,
    v_document_type || ' Reversal',
    v_document_no,
    p_description,
    v_source_type,
    v_source_no,
    v_lines,
    p_posted_by
  );
end;
$$;

-- Resolves the account an expense should hit: its mapped category, else the configured default.
create or replace function public._gl_expense_account(p_expense_category text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_account_no text;
begin
  select m."AccountNo" into v_account_no
  from public."GLExpenseCategoryMap" m
  where m."ExpenseCategory" = trim(coalesce(p_expense_category, ''));

  if v_account_no is null then
    select s."DefaultExpenseAccountNo" into v_account_no from public."GLSetup" s limit 1;
  end if;

  if v_account_no is null then
    raise exception 'No expense account is configured. Set a Default Expense Account in G/L Setup.';
  end if;

  return v_account_no;
end;
$$;

-- ============================================================================
-- 5. Chart of accounts + setup maintenance
-- ============================================================================

create or replace function public.admin_list_gl_accounts(
  p_admin_username text,
  p_admin_password text,
  p_include_inactive boolean default true
)
returns table(account_no text, name text, account_type text, direct_posting boolean, is_active boolean, balance numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Balance is returned in the account's NATURAL sign, not raw signed Amount: a liability with
  -- 5,000 credited reads as 5,000 owed, not -5,000, which is how anyone reading a chart expects
  -- it. Asset/Expense are debit-natured; Liability/Equity/Income are credit-natured.
  return query
    select a."AccountNo"::text, a."Name"::text, a."AccountType"::text, a."DirectPosting", a."IsActive",
           coalesce((
             select case when a."AccountType" in ('Asset', 'Expense') then sum(e."Amount") else -sum(e."Amount") end
             from public."GLEntries" e where e."AccountNo" = a."AccountNo"
           ), 0)::numeric
    from public."GLAccounts" a
    where p_include_inactive or a."IsActive"
    order by a."AccountNo";
end;
$$;

grant execute on function public.admin_list_gl_accounts(text, text, boolean) to anon;

create or replace function public.admin_upsert_gl_account(
  p_admin_username text,
  p_admin_password text,
  p_account_no text,
  p_name text,
  p_account_type text,
  p_direct_posting boolean default true,
  p_is_active boolean default true
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

  if nullif(trim(coalesce(p_account_no, '')), '') is null then
    raise exception 'Account No. is required.';
  end if;

  if nullif(trim(coalesce(p_name, '')), '') is null then
    raise exception 'Account Name is required.';
  end if;

  if p_account_type not in ('Asset', 'Liability', 'Equity', 'Income', 'Expense') then
    raise exception 'Account Type must be Asset, Liability, Equity, Income or Expense.';
  end if;

  insert into public."GLAccounts" ("AccountNo", "Name", "AccountType", "DirectPosting", "IsActive")
  values (trim(p_account_no), trim(p_name), p_account_type, coalesce(p_direct_posting, true), coalesce(p_is_active, true))
  on conflict ("AccountNo") do update set
    "Name" = excluded."Name",
    "AccountType" = excluded."AccountType",
    "DirectPosting" = excluded."DirectPosting",
    "IsActive" = excluded."IsActive";
end;
$$;

grant execute on function public.admin_upsert_gl_account(text, text, text, text, text, boolean, boolean) to anon;

create or replace function public.admin_get_gl_setup(p_admin_username text, p_admin_password text)
returns table(inventory_account_no text, payable_account_no text, cash_account_no text, digital_account_no text, default_expense_account_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select s."InventoryAccountNo"::text, s."PayableAccountNo"::text, s."CashAccountNo"::text,
           s."DigitalAccountNo"::text, s."DefaultExpenseAccountNo"::text
    from public."GLSetup" s limit 1;
end;
$$;

grant execute on function public.admin_get_gl_setup(text, text) to anon;

create or replace function public.admin_set_gl_setup(
  p_admin_username text,
  p_admin_password text,
  p_inventory_account_no text,
  p_payable_account_no text,
  p_cash_account_no text,
  p_digital_account_no text,
  p_default_expense_account_no text
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

  update public."GLSetup"
     set "InventoryAccountNo" = nullif(trim(coalesce(p_inventory_account_no, '')), ''),
         "PayableAccountNo" = nullif(trim(coalesce(p_payable_account_no, '')), ''),
         "CashAccountNo" = nullif(trim(coalesce(p_cash_account_no, '')), ''),
         "DigitalAccountNo" = nullif(trim(coalesce(p_digital_account_no, '')), ''),
         "DefaultExpenseAccountNo" = nullif(trim(coalesce(p_default_expense_account_no, '')), ''),
         "UpdatedBy" = p_admin_username,
         "UpdatedAtUtc" = now()
   where "Id";
end;
$$;

grant execute on function public.admin_set_gl_setup(text, text, text, text, text, text, text) to anon;

create or replace function public.admin_list_gl_expense_category_map(p_admin_username text, p_admin_password text)
returns table(expense_category text, account_no text, account_name text, is_mapped boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Lists every category that has actually appeared on a synced expense, mapped or not, so the
  -- unmapped ones are visible and fixable rather than silently falling into the default account.
  return query
    select c.category::text,
           m."AccountNo"::text,
           a."Name"::text,
           (m."AccountNo" is not null)
    from (
      select distinct nullif(trim(coalesce("ExpenseCategory", '')), '') as category
      from public."ExpenseEntryHeader"
      where nullif(trim(coalesce("ExpenseCategory", '')), '') is not null
    ) c
    left join public."GLExpenseCategoryMap" m on m."ExpenseCategory" = c.category
    left join public."GLAccounts" a on a."AccountNo" = m."AccountNo"
    order by (m."AccountNo" is not null), c.category;
end;
$$;

grant execute on function public.admin_list_gl_expense_category_map(text, text) to anon;

create or replace function public.admin_set_gl_expense_category_account(
  p_admin_username text,
  p_admin_password text,
  p_expense_category text,
  p_account_no text
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

  if nullif(trim(coalesce(p_account_no, '')), '') is null then
    delete from public."GLExpenseCategoryMap" where "ExpenseCategory" = trim(p_expense_category);
    return;
  end if;

  insert into public."GLExpenseCategoryMap" ("ExpenseCategory", "AccountNo", "UpdatedBy", "UpdatedAtUtc")
  values (trim(p_expense_category), trim(p_account_no), p_admin_username, now())
  on conflict ("ExpenseCategory") do update set
    "AccountNo" = excluded."AccountNo",
    "UpdatedBy" = excluded."UpdatedBy",
    "UpdatedAtUtc" = now();
end;
$$;

grant execute on function public.admin_set_gl_expense_category_account(text, text, text, text) to anon;

-- ============================================================================
-- 6. Reading the ledger
-- ============================================================================

create or replace function public.admin_list_gl_entries(
  p_admin_username text,
  p_admin_password text,
  p_from_date date default null,
  p_to_date date default null,
  p_account_no text default null,
  p_search text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  entry_no bigint, transaction_no bigint, posting_date date, account_no text, account_name text,
  description text, debit_amount numeric, credit_amount numeric, document_type text,
  document_no text, source_type text, source_no text, posted_by text, posted_at_utc timestamptz,
  total_count bigint, total_debit numeric, total_credit numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- total_debit/total_credit are window totals over the WHOLE filtered set, not just the page on
  -- screen, so the figures under the list describe the filter rather than the pagination.
  return query
    with filtered as (
      select e.*, a."Name" as account_name
      from public."GLEntries" e
      join public."GLAccounts" a on a."AccountNo" = e."AccountNo"
      where (p_from_date is null or e."PostingDate" >= p_from_date)
        and (p_to_date is null or e."PostingDate" <= p_to_date)
        and (p_account_no is null or trim(p_account_no) = '' or e."AccountNo" = p_account_no)
        and (
          p_search is null or trim(p_search) = ''
          or e."Description" ilike '%' || p_search || '%'
          or e."DocumentNo" ilike '%' || p_search || '%'
          or e."SourceNo" ilike '%' || p_search || '%'
        )
    )
    select f."EntryNo", f."TransactionNo", f."PostingDate", f."AccountNo"::text, f.account_name::text,
           f."Description"::text, f."DebitAmount", f."CreditAmount", f."DocumentType"::text,
           f."DocumentNo"::text, f."SourceType"::text, f."SourceNo"::text, f."PostedBy"::text, f."PostedAtUtc",
           count(*) over(), sum(f."DebitAmount") over(), sum(f."CreditAmount") over()
    from filtered f
    order by f."PostingDate" desc, f."EntryNo" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_gl_entries(text, text, date, date, text, text, int, int) to anon;

-- Trial balance: one row per account with movement, plus the natural-sign balance. The debit and
-- credit totals must be equal - if they are not, something wrote to GLEntries without going
-- through _gl_post.
create or replace function public.admin_get_gl_trial_balance(
  p_admin_username text,
  p_admin_password text,
  p_from_date date default null,
  p_to_date date default null
)
returns table(account_no text, name text, account_type text, debit_total numeric, credit_total numeric, balance numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select a."AccountNo"::text, a."Name"::text, a."AccountType"::text,
           coalesce(sum(e."DebitAmount"), 0)::numeric,
           coalesce(sum(e."CreditAmount"), 0)::numeric,
           case when a."AccountType" in ('Asset', 'Expense')
                then coalesce(sum(e."Amount"), 0)
                else -coalesce(sum(e."Amount"), 0) end::numeric
    from public."GLAccounts" a
    join public."GLEntries" e on e."AccountNo" = a."AccountNo"
    where (p_from_date is null or e."PostingDate" >= p_from_date)
      and (p_to_date is null or e."PostingDate" <= p_to_date)
    group by a."AccountNo", a."Name", a."AccountType"
    order by a."AccountNo";
end;
$$;

grant execute on function public.admin_get_gl_trial_balance(text, text, date, date) to anon;

-- ============================================================================
-- 7. Expenses -> G/L (manual batch, per direct decision)
-- ============================================================================

-- Posts synced expenses to the ledger for a date range. Chosen over an automatic trigger so
-- expenses can be reviewed and categorised BEFORE they reach the books - once posted, a mistake
-- can only be corrected by a reversing entry.
--
-- Re-running is safe: an expense already in GLEntries (DocumentType 'Expense', DocumentNo =
-- ReceiptNo) is skipped, so the same range can be posted repeatedly as new receipts sync in
-- without ever double-counting.
create or replace function public.admin_post_expenses_to_gl(
  p_admin_username text,
  p_admin_password text,
  p_from_date date,
  p_to_date date
)
returns table(posted_count int, skipped_count int, total_amount numeric, messages text[])
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_expense record;
  v_cash_account text;
  v_expense_account text;
  v_amount numeric;
  v_posted int := 0;
  v_skipped int := 0;
  v_total numeric := 0;
  v_messages text[] := array[]::text[];
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_from_date is null or p_to_date is null then
    raise exception 'A From and To date are both required.';
  end if;

  select s."CashAccountNo" into v_cash_account from public."GLSetup" s limit 1;
  if v_cash_account is null then
    raise exception 'No Cash account is configured. Set one in G/L Setup.';
  end if;

  for v_expense in
    select h."ReceiptNo", h."Date", h."NetAmount", h."Description", h."ExpenseCategory"
    from public."ExpenseEntryHeader" h
    where h."Date" >= p_from_date
      and h."Date" <= p_to_date
      and not exists (
        select 1 from public."GLEntries" e
        where e."DocumentType" = 'Expense' and e."DocumentNo" = h."ReceiptNo"
      )
    order by h."Date", h."ReceiptNo"
  loop
    v_amount := round(coalesce(v_expense."NetAmount", 0), 2);

    -- A zero or negative expense has nothing meaningful to post and would fail _gl_post's
    -- zero-amount check, so it is skipped by name rather than aborting the whole run.
    if v_amount <= 0 then
      v_skipped := v_skipped + 1;
      v_messages := v_messages || (v_expense."ReceiptNo" || ': amount is ' || v_amount || ' - skipped.');
      continue;
    end if;

    v_expense_account := public._gl_expense_account(v_expense."ExpenseCategory");

    perform public._gl_post(
      v_expense."Date",
      'Expense',
      v_expense."ReceiptNo",
      coalesce(nullif(trim(coalesce(v_expense."Description", '')), ''), 'Expense ' || v_expense."ReceiptNo"),
      'Expense',
      nullif(trim(coalesce(v_expense."ExpenseCategory", '')), ''),
      jsonb_build_array(
        jsonb_build_object('account_no', v_expense_account, 'amount', v_amount),
        jsonb_build_object('account_no', v_cash_account, 'amount', -v_amount)
      ),
      p_admin_username
    );

    v_posted := v_posted + 1;
    v_total := v_total + v_amount;
  end loop;

  return query select v_posted, v_skipped, v_total, v_messages;
end;
$$;

grant execute on function public.admin_post_expenses_to_gl(text, text, date, date) to anon;
