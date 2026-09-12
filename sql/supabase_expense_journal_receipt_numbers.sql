-- Per direct follow-up: Expense Journal entries were showing up in the Dashboard's Expense Today/
-- This Month totals (supabase_expense_journal_tables.sql) but NOT on the "Posted Expenses" list
-- itself (expense-entries.html / admin_list_expense_entries, supabase_expense_entry_tables.sql) -
-- that RPC only ever read from the desktop-synced ExpenseEntryHeader table. Per "map it as
-- EXP-000000001", journal entries now get their own ReceiptNo (format EXP-000000001, 000000002, ...
-- - same 9-digit padding style as the desktop's own RS-0000010523 receipt numbers, just a distinct
-- EXP- prefix so the two sources are never ambiguous) and admin_list_expense_entries is redefined to
-- union both sources, so a journal entry now shows up on Posted Expenses right alongside real
-- desktop-posted ones.
--
-- Journal entries obviously have no ItemLedgerEntry lines (supabase_expense_entry_tables.sql's
-- ExpenseEntryLines - that only exists for the desktop's per-item EXPENSE checkout flow), so the
-- "Lines" column's View link is suppressed client-side for any EXP- receipt (see js/expenseEntries.
-- js) rather than sending someone to a page that can only ever show "no lines".
--
-- Run this in the Supabase SQL Editor AFTER supabase_expense_journal_tables.sql.

create sequence if not exists public."ExpenseJournalReceiptNoSeq" start 1;

alter table public."ExpenseJournalEntries" add column if not exists "ReceiptNo" varchar(50);

create unique index if not exists "UX_ExpenseJournalEntries_ReceiptNo"
  on public."ExpenseJournalEntries" ("ReceiptNo") where "ReceiptNo" is not null;

comment on column public."ExpenseJournalEntries"."ReceiptNo" is 'EXP-000000001-style receipt number, assigned once at insert from ExpenseJournalReceiptNoSeq - lets this journal entry appear on the Posted Expenses list (admin_list_expense_entries) alongside desktop-posted receipts.';

-- ---------------------------------------------------------------------------
-- admin_add_expense_journal_entry: redefined (return columns changed - drop required) to assign and
-- return the new ReceiptNo.

drop function if exists public.admin_add_expense_journal_entry(text, text, text, text, numeric, date, text);

create or replace function public.admin_add_expense_journal_entry(
  p_admin_username text,
  p_admin_password text,
  p_expense_category text,
  p_description text,
  p_amount numeric,
  p_entry_date date default null,
  p_warehouse text default null
)
returns table(
  entry_id uuid,
  receipt_no text,
  entry_date date,
  expense_category text,
  description text,
  amount numeric,
  warehouse text,
  created_by text,
  created_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_category text := trim(coalesce(p_expense_category, ''));
  v_entry_date date := coalesce(p_entry_date, (now() at time zone 'Asia/Manila')::date);
  v_receipt_no text := 'EXP-' || lpad(nextval('public."ExpenseJournalReceiptNoSeq"')::text, 9, '0');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if v_category = '' then
    raise exception 'Expense category is required.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero.';
  end if;

  return query
    insert into public."ExpenseJournalEntries"
      ("ReceiptNo", "EntryDate", "ExpenseCategory", "Description", "Amount", "Warehouse", "CreatedBy")
    values (v_receipt_no, v_entry_date, v_category, nullif(trim(coalesce(p_description, '')), ''), p_amount, nullif(trim(coalesce(p_warehouse, '')), ''), p_admin_username)
    returning "EntryID", "ReceiptNo"::text, "EntryDate", "ExpenseCategory"::text, "Description"::text, "Amount", "Warehouse"::text, "CreatedBy"::text, "CreatedAtUtc";
end;
$$;

grant execute on function public.admin_add_expense_journal_entry(text, text, text, text, numeric, date, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_list_expense_journal_entries: redefined (return columns changed - drop required) to surface
-- ReceiptNo in the Expense Journal page's own list too.

drop function if exists public.admin_list_expense_journal_entries(text, text, text, text, int, int);

create or replace function public.admin_list_expense_journal_entries(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_period text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  entry_id uuid,
  receipt_no text,
  entry_date date,
  expense_category text,
  description text,
  amount numeric,
  warehouse text,
  created_by text,
  created_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
  v_today date;
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_period in ('month', 'today') then
    v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
    v_month_end := (v_month_start + interval '1 month')::date;
    v_today := (now() at time zone 'Asia/Manila')::date;
  end if;

  return query
    select "EntryID", "ReceiptNo"::text, "EntryDate", "ExpenseCategory"::text, "Description"::text, "Amount",
           "Warehouse"::text, "CreatedBy"::text, "CreatedAtUtc",
           count(*) over()
    from public."ExpenseJournalEntries"
    where (p_period is distinct from 'month' or ("EntryDate" >= v_month_start and "EntryDate" < v_month_end))
      and (p_period is distinct from 'today' or "EntryDate" = v_today)
      and (
        p_search is null or trim(p_search) = ''
        or "Description" ilike '%' || p_search || '%'
        or "ExpenseCategory" ilike '%' || p_search || '%'
        or "CreatedBy" ilike '%' || p_search || '%'
        or "Warehouse" ilike '%' || p_search || '%'
        or "ReceiptNo" ilike '%' || p_search || '%'
      )
    order by "CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_expense_journal_entries(text, text, text, text, int, int) to anon;

-- ---------------------------------------------------------------------------
-- Backfill: assign the one existing journal entry (added before ReceiptNo existed) its receipt
-- number. Guarded on "ReceiptNo" is null plus its own distinguishing fields, so this is a no-op if
-- already run, and can't touch any other row.

update public."ExpenseJournalEntries"
set "ReceiptNo" = 'EXP-' || lpad(nextval('public."ExpenseJournalReceiptNoSeq"')::text, 9, '0')
where "ReceiptNo" is null
  and "ExpenseCategory" = 'TRUCK-EXPENSE - GAS/TOLL/PETTYCASH'
  and "Amount" = 2500.00
  and "EntryDate" = '2026-09-10'
  and "Description" = 'Truck expense gas for trip 11/09/2026';

-- ---------------------------------------------------------------------------
-- admin_list_expense_entries: redefined (same signature/return shape, so no drop needed) to union
-- ExpenseJournalEntries (only rows that already have a ReceiptNo - i.e. everything from this point
-- on) into the same list expense-entries.html reads, so a journal entry shows up on Posted Expenses
-- exactly like a desktop-posted one, just tagged with its EXP- receipt number instead of an RS- one.

create or replace function public.admin_list_expense_entries(p_admin_username text, p_admin_password text, p_search text default null, p_receipt_no text default null, p_period text default null, p_page int default 1, p_page_size int default 50)
returns table(
  receipt_no text,
  warehouse text,
  expense_category text,
  description text,
  user_id text,
  entry_date date,
  entry_time text,
  quantity numeric,
  price numeric,
  discount numeric,
  gross_amount numeric,
  net_amount numeric,
  store_no text,
  pos_terminal_no text,
  transaction_no text,
  eod_id text,
  synced_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
  v_today date;
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_period in ('month', 'today') then
    v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
    v_month_end := (v_month_start + interval '1 month')::date;
    v_today := (now() at time zone 'Asia/Manila')::date;
  end if;

  return query
    with combined as (
      select "ReceiptNo"::text as receipt_no, "Warehouse"::text as warehouse, "ExpenseCategory"::text as expense_category,
             "Description"::text as description, "UserID"::text as user_id, "Date" as entry_date, "Time"::text as entry_time,
             "Quantity" as quantity, "Price" as price, "Discount" as discount, "GrossAmount" as gross_amount, "NetAmount" as net_amount,
             "StoreNo"::text as store_no, "POSTerminalNo"::text as pos_terminal_no, "TransactionNo"::text as transaction_no,
             "EODID"::text as eod_id, "SyncedAtUtc" as synced_at_utc
      from public."ExpenseEntryHeader"
      union all
      select "ReceiptNo"::text, "Warehouse"::text, "ExpenseCategory"::text, "Description"::text, "CreatedBy"::text,
             "EntryDate", to_char("CreatedAtUtc" at time zone 'Asia/Manila', 'HH24:MI:SS'),
             null::numeric, "Amount", null::numeric, "Amount", "Amount",
             null::text, null::text, null::text, null::text, "CreatedAtUtc"
      from public."ExpenseJournalEntries"
      where "ReceiptNo" is not null
    )
    select combined.receipt_no, combined.warehouse, combined.expense_category, combined.description, combined.user_id,
           combined.entry_date, combined.entry_time, combined.quantity, combined.price, combined.discount,
           combined.gross_amount, combined.net_amount, combined.store_no, combined.pos_terminal_no,
           combined.transaction_no, combined.eod_id, combined.synced_at_utc,
           count(*) over()
    from combined
    where (p_period is distinct from 'month' or (combined.entry_date >= v_month_start and combined.entry_date < v_month_end))
      and (p_period is distinct from 'today' or combined.entry_date = v_today)
      and (
        (p_receipt_no is not null and trim(p_receipt_no) <> '' and combined.receipt_no = p_receipt_no)
        or (
          (p_receipt_no is null or trim(p_receipt_no) = '')
          and (
            p_search is null or trim(p_search) = ''
            or combined.receipt_no ilike '%' || p_search || '%'
            or combined.description ilike '%' || p_search || '%'
            or combined.expense_category ilike '%' || p_search || '%'
            or combined.user_id ilike '%' || p_search || '%'
            or combined.warehouse ilike '%' || p_search || '%'
          )
        )
      )
    order by combined.synced_at_utc desc nulls last, combined.entry_date desc nulls last
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;
