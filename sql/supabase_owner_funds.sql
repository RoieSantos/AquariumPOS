-- Owner Funds (Web Portal, super users only) - per "how can I input my income funds to the
-- business.. e.g. I used my own funds to pay for a bill how can we track it?". A small owner's
-- ledger of money moving between the owner and the business, each entry posted to the G/L:
--
--   Entry type      Method          G/L posting
--   Capital In      Cash / Digital  Dr Cash or Digital          Cr 3000 Owner's Equity
--   Owner Loan      Cash / Digital  Dr Cash or Digital          Cr 2100 Due to Owner
--   Capital In      Paid Directly   Dr <expense account>        Cr 3000 Owner's Equity
--   Owner Loan      Paid Directly   Dr <expense account>        Cr 2100 Due to Owner
--   Loan Repayment  Cash / Digital  Dr 2100 Due to Owner        Cr Cash or Digital
--   Drawing         Cash / Digital  Dr 3100 Owner's Drawings    Cr Cash or Digital
--
-- "Paid Directly" = the owner paid a business expense from their own pocket, so no business cash
-- moved. It also creates the Expense Journal entry (EXP- receipt) so the expense still shows in
-- Expenses / Dashboard, and posts that expense to the G/L right away under DocumentType 'Expense' +
-- its receipt no. - the same key "Post Expenses to G/L" uses to skip already-posted expenses, so it
-- is never posted a second time against Cash. Bills & Dues uses this for "Paid by: Owner"
-- (supabase_business_bills.sql).
--
-- Capital vs loan: Capital In is a permanent investment; Owner Loan is money the business owes back
-- (Loan Repayment reduces it, and can't exceed what's outstanding). Drawing = owner takes money out.
-- Voiding posts a reversing G/L entry (the ledger stays append-only) and deletes a Paid Directly
-- entry's Expense Journal entry.
--
-- admin_get_expense_paid_by feeds the Expenses page's "Paid By" column (Business / Owner).
--
-- Run AFTER supabase_general_ledger.sql and supabase_expense_journal_receipt_numbers.sql.
-- Safe to re-run. Needs docs/owner-funds.html + docs/js/ownerFunds.js.

-- ---------------------------------------------------------------------------
-- Accounts (3000 Owner's Equity is already seeded by supabase_general_ledger.sql).
insert into public."GLAccounts" ("AccountNo", "Name", "AccountType", "DirectPosting")
select * from (values
  ('2100', 'Due to Owner',       'Liability', true),
  ('3000', 'Owner''s Equity',    'Equity',    true),
  ('3100', 'Owner''s Drawings',  'Equity',    true)
) as seed("AccountNo", "Name", "AccountType", "DirectPosting")
where not exists (select 1 from public."GLAccounts" a where a."AccountNo" = seed."AccountNo");

create sequence if not exists public."OwnerFundEntryNoSeq" as bigint;

create table if not exists public."OwnerFundEntries" (
    "EntryID" uuid primary key default gen_random_uuid(),
    "EntryNo" varchar(20) not null unique,             -- OWN-000001
    "EntryDate" date not null,
    "EntryType" varchar(20) not null check ("EntryType" in ('Capital In', 'Owner Loan', 'Loan Repayment', 'Drawing')),
    "Method" varchar(20) not null check ("Method" in ('Cash', 'Digital', 'Paid Directly')),
    "Amount" numeric(18, 2) not null check ("Amount" > 0),
    "Description" varchar(500),
    "Warehouse" text,
    "ExpenseCategory" varchar(200),                    -- Paid Directly only
    "ExpenseJournalEntryID" uuid,                      -- Paid Directly only
    "ExpenseReceiptNo" varchar(50),                    -- Paid Directly only
    "BusinessBillPaymentID" uuid,                      -- set when made by Bills & Dues "Paid by: Owner"
    "GLTransactionNo" bigint,
    "IsVoid" boolean not null default false,
    "VoidedBy" varchar(100),
    "VoidedAtUtc" timestamptz,
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now()
);

alter table public."OwnerFundEntries" enable row level security;
revoke all on public."OwnerFundEntries" from anon, authenticated;
create index if not exists "IX_OwnerFundEntries_Date" on public."OwnerFundEntries" ("EntryDate");

-- Owner Loan total minus Loan Repayments, not voided.
create or replace function public._owner_loan_outstanding()
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(sum(case "EntryType" when 'Owner Loan' then "Amount" when 'Loan Repayment' then -"Amount" else 0 end), 0)
  from public."OwnerFundEntries"
  where not "IsVoid";
$$;

-- ---------------------------------------------------------------------------
-- Shared by admin_add_owner_fund_entry and admin_pay_business_bill (both check access first).
-- For Paid Directly the Expense Journal entry must already exist (p_expense_entry_id/receipt).
create or replace function public._owner_fund_add(
  p_entry_type text,
  p_entry_date date,
  p_amount numeric,
  p_method text,
  p_description text,
  p_warehouse text,
  p_expense_category text,
  p_expense_entry_id uuid,
  p_expense_receipt_no text,
  p_business_bill_payment_id uuid,
  p_user text
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_date date := coalesce(p_entry_date, (now() at time zone 'Asia/Manila')::date);
  v_entry_no text := 'OWN-' || lpad(nextval('public."OwnerFundEntryNoSeq"')::text, 6, '0');
  v_fund_account text;
  v_owner_account text;
  v_lines jsonb;
  v_desc text;
  v_tx bigint;
  v_id uuid;
begin
  if p_entry_type not in ('Capital In', 'Owner Loan', 'Loan Repayment', 'Drawing') then
    raise exception 'Invalid entry type: %', p_entry_type;
  end if;
  if p_method not in ('Cash', 'Digital', 'Paid Directly') then
    raise exception 'Invalid method: %', p_method;
  end if;
  if v_amount <= 0 then
    raise exception 'Amount must be greater than zero.';
  end if;
  if p_method = 'Paid Directly' then
    if p_entry_type not in ('Capital In', 'Owner Loan') then
      raise exception '"Paid Directly" only applies to Capital In or Owner Loan.';
    end if;
    if p_expense_receipt_no is null then
      raise exception 'A Paid Directly entry needs its Expense Journal entry.';
    end if;
  end if;
  if p_entry_type = 'Loan Repayment' and v_amount > public._owner_loan_outstanding() then
    raise exception 'Repayment (%) is more than the outstanding owner loan (%).', v_amount, public._owner_loan_outstanding();
  end if;

  v_owner_account := case p_entry_type
    when 'Capital In' then '3000'
    when 'Owner Loan' then '2100'
    when 'Loan Repayment' then '2100'
    when 'Drawing' then '3100'
  end;

  if p_method = 'Paid Directly' then
    v_fund_account := public._gl_expense_account(p_expense_category);
  elsif p_method = 'Cash' then
    select s."CashAccountNo" into v_fund_account from public."GLSetup" s limit 1;
  else
    select s."DigitalAccountNo" into v_fund_account from public."GLSetup" s limit 1;
  end if;
  if v_fund_account is null then
    raise exception 'No % account is configured. Set one in G/L Setup.', p_method;
  end if;

  v_desc := p_entry_type || ' - ' || coalesce(nullif(trim(coalesce(p_description, '')), ''), v_entry_no);

  -- Money in (Capital In / Owner Loan): Dr fund, Cr owner account. Money out: the reverse.
  if p_entry_type in ('Capital In', 'Owner Loan') then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_no', v_fund_account, 'amount', v_amount),
      jsonb_build_object('account_no', v_owner_account, 'amount', -v_amount));
  else
    v_lines := jsonb_build_array(
      jsonb_build_object('account_no', v_owner_account, 'amount', v_amount),
      jsonb_build_object('account_no', v_fund_account, 'amount', -v_amount));
  end if;

  if p_method = 'Paid Directly' then
    -- Posted as the expense itself, so "Post Expenses to G/L" sees it as already posted.
    v_tx := public._gl_post(v_date, 'Expense', p_expense_receipt_no,
      v_desc || ' (paid by owner, ' || v_entry_no || ')', 'Owner', v_entry_no, v_lines, p_user);
  else
    v_tx := public._gl_post(v_date, 'Owner Funds', v_entry_no, v_desc, 'Owner', v_entry_no, v_lines, p_user);
  end if;

  insert into public."OwnerFundEntries"
    ("EntryNo", "EntryDate", "EntryType", "Method", "Amount", "Description", "Warehouse", "ExpenseCategory",
     "ExpenseJournalEntryID", "ExpenseReceiptNo", "BusinessBillPaymentID", "GLTransactionNo", "CreatedBy")
  values
    (v_entry_no, v_date, p_entry_type, p_method, v_amount, nullif(trim(coalesce(p_description, '')), ''),
     nullif(trim(coalesce(p_warehouse, '')), ''),
     case when p_method = 'Paid Directly' then nullif(trim(coalesce(p_expense_category, '')), '') end,
     p_expense_entry_id, p_expense_receipt_no, p_business_bill_payment_id, v_tx, p_user)
  returning "EntryID" into v_id;

  return v_id;
end;
$$;

-- Marks the entry void and reverses its G/L posting. Does NOT delete the Expense Journal entry -
-- callers do that after (admin_delete_expense_journal_entry refuses while a live entry links it).
create or replace function public._owner_fund_void(p_entry_id uuid, p_user text)
returns public."OwnerFundEntries"
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."OwnerFundEntries"%rowtype;
begin
  select * into v_row from public."OwnerFundEntries" where "EntryID" = p_entry_id for update;
  if not found or v_row."IsVoid" then
    raise exception 'Owner fund entry not found or already voided.';
  end if;
  if v_row."EntryType" = 'Owner Loan' and public._owner_loan_outstanding() - v_row."Amount" < 0 then
    raise exception 'Void the Loan Repayments first - voiding this loan would leave more repaid than was lent.';
  end if;

  update public."OwnerFundEntries"
  set "IsVoid" = true, "VoidedBy" = p_user, "VoidedAtUtc" = now()
  where "EntryID" = p_entry_id;

  if v_row."GLTransactionNo" is not null then
    perform public._gl_reverse(v_row."GLTransactionNo", (now() at time zone 'Asia/Manila')::date,
      'Void ' || v_row."EntryNo", p_user);
  end if;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPCs

drop function if exists public.admin_list_owner_fund_entries(text, text, int);

create or replace function public.admin_list_owner_fund_entries(
  p_admin_username text,
  p_admin_password text,
  p_limit int default 500
)
returns table(
  entry_id uuid,
  entry_no text,
  entry_date date,
  entry_type text,
  method text,
  amount numeric,
  description text,
  warehouse text,
  expense_category text,
  expense_receipt_no text,
  bill_name text,
  is_void boolean,
  created_by text,
  created_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."EntryID", o."EntryNo"::text, o."EntryDate", o."EntryType"::text, o."Method"::text, o."Amount",
           o."Description"::text, o."Warehouse", o."ExpenseCategory"::text, o."ExpenseReceiptNo"::text,
           b."Name"::text, o."IsVoid", o."CreatedBy"::text, o."CreatedAtUtc"
    from public."OwnerFundEntries" o
    left join public."BusinessBillPayments" bp on bp."PaymentID" = o."BusinessBillPaymentID"
    left join public."BusinessBills" b on b."BillID" = bp."BillID"
    order by o."EntryDate" desc, o."CreatedAtUtc" desc
    limit least(greatest(coalesce(p_limit, 500), 1), 2000);
end;
$$;

grant execute on function public.admin_list_owner_fund_entries(text, text, int) to anon;

-- All-time totals (not voided). net_invested = capital in - drawings (the owner's equity from
-- this page; profit/loss is on top of that in the G/L).
drop function if exists public.admin_get_owner_funds_summary(text, text);

create or replace function public.admin_get_owner_funds_summary(p_admin_username text, p_admin_password text)
returns table(capital_in numeric, drawings numeric, loans_in numeric, loans_repaid numeric,
              loan_outstanding numeric, net_invested numeric, paid_directly numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select coalesce(sum("Amount") filter (where "EntryType" = 'Capital In'), 0),
           coalesce(sum("Amount") filter (where "EntryType" = 'Drawing'), 0),
           coalesce(sum("Amount") filter (where "EntryType" = 'Owner Loan'), 0),
           coalesce(sum("Amount") filter (where "EntryType" = 'Loan Repayment'), 0),
           coalesce(sum("Amount") filter (where "EntryType" = 'Owner Loan'), 0)
             - coalesce(sum("Amount") filter (where "EntryType" = 'Loan Repayment'), 0),
           coalesce(sum("Amount") filter (where "EntryType" = 'Capital In'), 0)
             - coalesce(sum("Amount") filter (where "EntryType" = 'Drawing'), 0),
           coalesce(sum("Amount") filter (where "Method" = 'Paid Directly'), 0)
    from public."OwnerFundEntries"
    where not "IsVoid";
end;
$$;

grant execute on function public.admin_get_owner_funds_summary(text, text) to anon;

-- Paid Directly needs p_expense_category; it creates the Expense Journal entry in the same call.
drop function if exists public.admin_add_owner_fund_entry(text, text, text, date, numeric, text, text, text, text);

create or replace function public.admin_add_owner_fund_entry(
  p_admin_username text,
  p_admin_password text,
  p_entry_type text,
  p_entry_date date,
  p_amount numeric,
  p_method text,
  p_description text default null,
  p_warehouse text default null,
  p_expense_category text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_expense_id uuid;
  v_receipt text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_method = 'Paid Directly' then
    if nullif(trim(coalesce(p_expense_category, '')), '') is null then
      raise exception 'Pick the Expense Category of what you paid for.';
    end if;
    if p_entry_type not in ('Capital In', 'Owner Loan') then
      raise exception '"Paid Directly" only applies to Capital In or Owner Loan.';
    end if;
    select e.entry_id, e.receipt_no into v_expense_id, v_receipt
    from public.admin_add_expense_journal_entry(
      p_admin_username, p_admin_password, trim(p_expense_category),
      coalesce(nullif(trim(coalesce(p_description, '')), ''), 'Paid by owner') || ' (paid by owner)',
      p_amount, p_entry_date, p_warehouse
    ) e;
  end if;

  return public._owner_fund_add(p_entry_type, p_entry_date, p_amount, p_method, p_description, p_warehouse,
    p_expense_category, v_expense_id, v_receipt, null, p_admin_username);
end;
$$;

grant execute on function public.admin_add_owner_fund_entry(text, text, text, date, numeric, text, text, text, text) to anon;

drop function if exists public.admin_void_owner_fund_entry(text, text, uuid);

create or replace function public.admin_void_owner_fund_entry(p_admin_username text, p_admin_password text, p_entry_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."OwnerFundEntries"%rowtype;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if exists (select 1 from public."OwnerFundEntries" where "EntryID" = p_entry_id and "BusinessBillPaymentID" is not null) then
    raise exception 'This entry came from a Bills & Dues payment - void that payment instead.';
  end if;

  v_row := public._owner_fund_void(p_entry_id, p_admin_username);

  if v_row."ExpenseJournalEntryID" is not null then
    delete from public."ExpenseJournalEntries" where "EntryID" = v_row."ExpenseJournalEntryID";
  end if;
end;
$$;

grant execute on function public.admin_void_owner_fund_entry(text, text, uuid) to anon;

-- Which of these expense receipts the owner paid personally (Expenses page "Paid By" column) - one
-- row per owner-paid receipt; anything not returned was paid by the business.
drop function if exists public.admin_get_expense_paid_by(text, text, text[]);

create or replace function public.admin_get_expense_paid_by(p_admin_username text, p_admin_password text, p_receipt_nos text[])
returns table(receipt_no text, entry_type text, owner_entry_no text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select o."ExpenseReceiptNo"::text, o."EntryType"::text, o."EntryNo"::text
    from public."OwnerFundEntries" o
    where o."ExpenseReceiptNo" = any(coalesce(p_receipt_nos, array[]::text[]))
      and o."Method" = 'Paid Directly'
      and not o."IsVoid";
end;
$$;

grant execute on function public.admin_get_expense_paid_by(text, text, text[]) to anon;

-- ---------------------------------------------------------------------------
-- admin_delete_expense_journal_entry: redefined (same signature, from supabase_expense_journal_
-- tables.sql) to refuse deleting an expense the owner paid directly while its owner entry is live -
-- otherwise the G/L posting and Owner Funds would be left pointing at a deleted expense.

create or replace function public.admin_delete_expense_journal_entry(p_admin_username text, p_admin_password text, p_entry_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_owner_no text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select o."EntryNo" into v_owner_no
  from public."OwnerFundEntries" o
  where o."ExpenseJournalEntryID" = p_entry_id and not o."IsVoid"
  limit 1;
  if v_owner_no is not null then
    return query select false, ('This expense was paid by the owner (' || v_owner_no || ') - void it on Owner Funds or Bills & Dues instead.')::text;
    return;
  end if;

  delete from public."ExpenseJournalEntries" where "EntryID" = p_entry_id;

  if not found then
    return query select false, 'Entry not found.'::text;
    return;
  end if;

  return query select true, 'Entry deleted.'::text;
end;
$$;

grant execute on function public.admin_delete_expense_journal_entry(text, text, uuid) to anon;

notify pgrst, 'reload schema';

-- Verification - one result.
select 'function' as kind, p.proname::text as name
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like any (array['%owner_fund%', '_owner_loan_outstanding', 'admin_get_expense_paid_by'])
union all
select 'gl account', "AccountNo" || ' ' || "Name" from public."GLAccounts" where "AccountNo" in ('2100', '3000', '3100')
order by 1, 2;
