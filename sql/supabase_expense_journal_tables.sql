-- Expense Journal: lets a super user log a cash/manual expense directly from the portal (Category +
-- Description + Amount), for spending that never goes through the desktop POS's EXPENSE checkout
-- flow (so never lands in ExpenseEntryHeader/ExpenseEntryLines - see supabase_expense_entry_tables.
-- sql) and so was previously untracked anywhere the portal could see. Per direct request: "create me
-- a expense journal.. this way I can add expense from the portal .. use the same expense category
-- with description and amount".
--
-- Deliberately a separate table from ExpenseEntryHeader rather than inserting into it - that table
-- mirrors a specific desktop document shape (ReceiptNo/EODID/POSTerminalNo/ItemLedgerEntry lines
-- etc.) that a manually-typed portal entry has no equivalent for. This table is intentionally much
-- simpler: one row per manual entry, no line items.
--
-- Category source: there is no master expense-category table synced to Supabase (the desktop's
-- ExpenseCategorySetup table - see ExpenseCategorySetupForm.cs - stays local, only the chosen
-- category STRING gets synced onto each posted ExpenseEntryHeader row). Per direct decision, the
-- portal's category dropdown is built from admin_list_expense_journal_categories below, which reads
-- the distinct category values already in use (from both ExpenseEntryHeader and this table) rather
-- than standing up a second, separately-maintained category list that could drift from the real one.
--
-- Access: super users only (admin_*, is_admin_authorized), same trust level as the existing
-- read-only Expenses page - this is financial data and, unlike that page, this one WRITES. RLS stays
-- enabled with no policies and direct anon table access is revoked, so a security definer function
-- is the only path in, same pattern as PayrollLedgerEntries (supabase_payroll_ledger.sql).
--
-- Run this in the Supabase SQL Editor AFTER supabase_expense_entry_tables.sql.

create table if not exists public."ExpenseJournalEntries" (
    "EntryID" uuid primary key default gen_random_uuid(),
    "EntryDate" date not null,
    "ExpenseCategory" varchar(200) not null,
    "Description" varchar(500),
    "Amount" numeric(18, 2) not null check ("Amount" > 0),
    "Warehouse" varchar(200),
    "CreatedBy" varchar(100) not null,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."ExpenseJournalEntries" enable row level security;
revoke all on public."ExpenseJournalEntries" from anon, authenticated;

create index if not exists "IX_ExpenseJournalEntries_EntryDate" on public."ExpenseJournalEntries" ("EntryDate");
create index if not exists "IX_ExpenseJournalEntries_ExpenseCategory" on public."ExpenseJournalEntries" ("ExpenseCategory");

comment on table public."ExpenseJournalEntries" is 'Manual expense log entered directly from the portal (super users only) - Category/Description/Amount, separate from the desktop-synced ExpenseEntryHeader document mirror.';

-- ---------------------------------------------------------------------------
-- admin_list_expense_journal_categories: distinct category values already in use, so the portal's
-- "Add Expense" form offers the same categories staff already use on the desktop instead of a blank
-- free-text box - pulled from both the desktop-synced ExpenseEntryHeader.ExpenseCategory and any
-- category already typed into this journal (so a custom category typed once shows up as a pick next
-- time, without needing its own management page).

drop function if exists public.admin_list_expense_journal_categories(text, text);

create or replace function public.admin_list_expense_journal_categories(p_admin_username text, p_admin_password text)
returns table(category text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select distinct c.category from (
      select trim("ExpenseCategory") as category from public."ExpenseEntryHeader"
      union
      select trim("ExpenseCategory") as category from public."ExpenseJournalEntries"
    ) c
    where c.category is not null and c.category <> ''
    order by 1;
end;
$$;

grant execute on function public.admin_list_expense_journal_categories(text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_add_expense_journal_entry: the actual write. p_entry_date defaults to "today" in the
-- Asia/Manila store timezone (same boundary convention used across the portal, e.g.
-- admin_get_expense_entry_summary below) rather than the database server's own date/timezone.

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
      ("EntryDate", "ExpenseCategory", "Description", "Amount", "Warehouse", "CreatedBy")
    values (v_entry_date, v_category, nullif(trim(coalesce(p_description, '')), ''), p_amount, nullif(trim(coalesce(p_warehouse, '')), ''), p_admin_username)
    returning "EntryID", "EntryDate", "ExpenseCategory"::text, "Description"::text, "Amount", "Warehouse"::text, "CreatedBy"::text, "CreatedAtUtc";
end;
$$;

grant execute on function public.admin_add_expense_journal_entry(text, text, text, text, numeric, date, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_delete_expense_journal_entry: lets a super user remove a mis-typed entry. Unlike the General
-- Ledger (gl-entries.html, reversing-entry-only by design), this journal is just a manual log with
-- no downstream postings pointing at it, so a straight delete is safe here.

drop function if exists public.admin_delete_expense_journal_entry(text, text, uuid);

create or replace function public.admin_delete_expense_journal_entry(p_admin_username text, p_admin_password text, p_entry_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
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

-- ---------------------------------------------------------------------------
-- admin_list_expense_journal_entries: paginated/filterable read, same p_period ('month'/'today')
-- convention as admin_list_expense_entries so this page can offer the same kind of filtering.

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
    select "EntryID", "EntryDate", "ExpenseCategory"::text, "Description"::text, "Amount",
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
      )
    order by "CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_expense_journal_entries(text, text, text, text, int, int) to anon;

-- ---------------------------------------------------------------------------
-- admin_get_expense_entry_summary: extended (not replaced) to fold ExpenseJournalEntries into the
-- same "Expense Today"/"Expense This Month" dashboard totals as the desktop-posted ExpenseEntryHeader
-- rows, per direct decision - the dashboard should reflect true total spend regardless of which of
-- the two the expense was recorded through. Signature is unchanged, so no drop/recreate of the
-- existing overload is needed - this replace just adds the journal amounts into each figure.

create or replace function public.admin_get_expense_entry_summary(p_admin_username text, p_admin_password text, p_warehouse_name text default null)
returns table(month_expense numeric, month_expense_count int, today_expense numeric, today_expense_count int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_month_start date;
  v_month_end date;
  v_today date;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  v_month_start := date_trunc('month', (now() at time zone 'Asia/Manila')::date)::date;
  v_month_end := (v_month_start + interval '1 month')::date;
  v_today := (now() at time zone 'Asia/Manila')::date;

  return query
    select
      (
        coalesce((select sum("NetAmount") from public."ExpenseEntryHeader"
                  where "Date" >= v_month_start and "Date" < v_month_end
                    and (p_warehouse_name is null or trim(p_warehouse_name) = '' or "Warehouse" = p_warehouse_name)), 0)
        +
        coalesce((select sum("Amount") from public."ExpenseJournalEntries"
                  where "EntryDate" >= v_month_start and "EntryDate" < v_month_end
                    and (p_warehouse_name is null or trim(p_warehouse_name) = '' or "Warehouse" = p_warehouse_name)), 0)
      )::numeric as month_expense,
      (
        coalesce((select count(*) from public."ExpenseEntryHeader"
                  where "Date" >= v_month_start and "Date" < v_month_end
                    and (p_warehouse_name is null or trim(p_warehouse_name) = '' or "Warehouse" = p_warehouse_name)), 0)
        +
        coalesce((select count(*) from public."ExpenseJournalEntries"
                  where "EntryDate" >= v_month_start and "EntryDate" < v_month_end
                    and (p_warehouse_name is null or trim(p_warehouse_name) = '' or "Warehouse" = p_warehouse_name)), 0)
      )::int as month_expense_count,
      (
        coalesce((select sum("NetAmount") from public."ExpenseEntryHeader"
                  where "Date" = v_today
                    and (p_warehouse_name is null or trim(p_warehouse_name) = '' or "Warehouse" = p_warehouse_name)), 0)
        +
        coalesce((select sum("Amount") from public."ExpenseJournalEntries"
                  where "EntryDate" = v_today
                    and (p_warehouse_name is null or trim(p_warehouse_name) = '' or "Warehouse" = p_warehouse_name)), 0)
      )::numeric as today_expense,
      (
        coalesce((select count(*) from public."ExpenseEntryHeader"
                  where "Date" = v_today
                    and (p_warehouse_name is null or trim(p_warehouse_name) = '' or "Warehouse" = p_warehouse_name)), 0)
        +
        coalesce((select count(*) from public."ExpenseJournalEntries"
                  where "EntryDate" = v_today
                    and (p_warehouse_name is null or trim(p_warehouse_name) = '' or "Warehouse" = p_warehouse_name)), 0)
      )::int as today_expense_count;
end;
$$;

grant execute on function public.admin_get_expense_entry_summary(text, text, text) to anon;
