-- Supabase/Postgres mirror of individual POSTED Expense Entries (the "EXPENSE" checkout flow in
-- MainForm.cs - staff adds one or more expense lines to the sale, then clicks POST/CHECKOUT).
--
-- This is a DIFFERENT thing from ExpenseReportHeader/ExpenseReportLines (supabase_expense_report_
-- tables.sql), which mirrors the aggregated, printed Expense Report for a date range. This table
-- instead gets one row per individual posted expense entry, in near-real-time, the moment it's
-- posted - same "channel 3, desktop -> Supabase directly, no portal read access yet" pattern as
-- supabase_orders_sync_tables.sql.
--
-- Source data (see MainForm.PostPendingExpenses -> OnlinefunctionsEvents.SyncExpenseEntryToSupabaseAsync):
--   Header <- dbo.TransactionHeader WHERE ReceiptNo = @receiptNo AND Type = 'EXPENSE'
--     (written by WriteSalesTransactionHeader at POST time).
--   Lines  <- dbo.ItemLedgerEntry WHERE DocumentNo = @receiptNo AND DocumentType = 'EXPENSE'
--     (one row per expense line item, written by PostInventoryEntry at POST time; ItemLedgerEntry.ID
--     is a local IDENTITY column, used here as LineID).
--
-- Sent from the desktop app using the SECRET/service-role key (bypasses RLS entirely), same as
-- every other one-way desktop -> Supabase sync in this codebase.
--
-- Portal viewing: an "Expenses" page (expense-entries.html / expense-entry-lines.html) reads
-- these through the admin_list_expense_entries / admin_list_expense_entry_lines functions below -
-- super-user-only (public.is_admin_authorized(), same access level and password-re-entry-on-
-- unlock trust model as Advance Orders), never through direct anon table access - RLS stays
-- enabled with no policies on both tables, so a security definer function is the only path in.

create table if not exists public."ExpenseEntryHeader" (
    "ReceiptNo" varchar(50) primary key,
    "Type" varchar(20) not null default 'EXPENSE',
    "StoreNo" varchar(20),
    "POSTerminalNo" varchar(20),
    "TransactionNo" varchar(50),
    "Quantity" numeric(18, 2),
    "Price" numeric(18, 2),
    "Discount" numeric(18, 2),
    "GrossAmount" numeric(18, 2),
    "NetAmount" numeric(18, 2),
    "Date" date,
    "Time" varchar(20),
    "UserID" varchar(100),
    "Description" varchar(500),
    "EODID" varchar(100),
    "ExpenseCategory" varchar(200),
    "SyncedAtUtc" timestamptz
);

alter table public."ExpenseEntryHeader" enable row level security;

-- Added per "add a new field Warehouse, this will send the current warehouse data into that
-- field": the machine's current warehouse at POST time (TransferOrderData.GetCurrentWarehouse -
-- same source already used for ExpenseReportHeader.WarehouseName in PostingEvents.PrintExpenseReport).
-- `add column if not exists` keeps this idempotent for a project where ExpenseEntryHeader was
-- already created before this column was introduced.
alter table public."ExpenseEntryHeader" add column if not exists "Warehouse" varchar(200);

create table if not exists public."ExpenseEntryLines" (
    "ReceiptNo" varchar(50) not null references public."ExpenseEntryHeader" ("ReceiptNo"),
    "LineID" varchar(50) not null,
    "EntryDate" timestamptz,
    "ItemCode" varchar(50),
    "VariationId" varchar(200),
    "StoreNo" varchar(20),
    "POSTerminalNo" varchar(20),
    "Quantity" numeric(18, 2),
    "UnitCost" numeric(18, 2),
    "TotalCost" numeric(18, 2),
    "Price" numeric(18, 2),
    "Discount" numeric(18, 2),
    "GrossAmount" numeric(18, 2),
    "NetAmount" numeric(18, 2),
    "Description" varchar(500),
    "UserID" varchar(100),
    "SyncedAtUtc" timestamptz,
    constraint "PK_ExpenseEntryLines" primary key ("ReceiptNo", "LineID")
);

alter table public."ExpenseEntryLines" enable row level security;

create index if not exists "IX_ExpenseEntryLines_ReceiptNo" on public."ExpenseEntryLines" ("ReceiptNo");
create index if not exists "IX_ExpenseEntryHeader_ExpenseCategory" on public."ExpenseEntryHeader" ("ExpenseCategory");

-- Direct table access stays fully blocked by RLS (no policies) - only the desktop app's
-- service-role key (which bypasses RLS) can write here, matching every other raw sync table.
revoke all on public."ExpenseEntryHeader" from anon, authenticated;
revoke all on public."ExpenseEntryLines" from anon, authenticated;

-- The desktop expense sync does a read-before-upsert through PostgREST (to check whether a
-- ReceiptNo / LineID row already exists), so it needs the same basic table privileges as the
-- other raw sync tables. RLS still stays enabled and there are no policies, so this only
-- enables the specific REST operations the sync uses.
grant select, insert, update on public."ExpenseEntryHeader" to anon, authenticated;
grant select, insert, update on public."ExpenseEntryLines" to anon, authenticated;

comment on table public."ExpenseEntryHeader" is 'Supabase copy of dbo.TransactionHeader rows where Type = EXPENSE - one row per posted Expense Entry (not the aggregated Expense Report).';
comment on table public."ExpenseEntryLines" is 'Supabase copy of dbo.ItemLedgerEntry rows where DocumentType = EXPENSE - one row per line item on a posted Expense Entry.';
comment on column public."ExpenseEntryHeader"."ReceiptNo" is 'Primary key, matches local TransactionHeader.ReceiptNo for the posted expense.';
comment on column public."ExpenseEntryLines"."LineID" is 'Local dbo.ItemLedgerEntry.ID (identity column) for this line.';

-- Read-only "Expenses" page (super users only, same as Advance Orders). Every call re-verifies
-- the acting staff member's username + password via public.is_admin_authorized() rather than
-- opening direct anon SELECT access - this is financial data.

drop function if exists public.admin_list_expense_entries(text, text, text, text);
drop function if exists public.admin_list_expense_entries(text, text, text, text, text);
drop function if exists public.admin_list_expense_entries(text, text, text, text, text, int, int);

-- p_receipt_no: exact filter, used by the lines drill-down page to fetch just that entry's header
-- - that call site doesn't pass p_page/p_page_size, so it just gets the (1, 50) defaults, fine
-- since exactly one matching row is expected.
-- p_search: free-text browsing filter (ReceiptNo/Description/ExpenseCategory/UserID/Warehouse),
-- ignored when p_receipt_no is set.
--
-- p_period: per "once I click the dashboard I want to be able to open the corresponding
-- data/page of entries filtered" - the "Expense This Month"/"Expense Today" dashboard cards link
-- here with p_period = 'month'/'today', reusing the exact same Asia/Manila boundary logic as
-- admin_get_expense_entry_summary so the list always matches what that card actually summed.
--
-- p_page/p_page_size (portal-wide pagination): total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
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
    select "ReceiptNo"::text, "Warehouse"::text, "ExpenseCategory"::text, "Description"::text, "UserID"::text,
           "Date", "Time"::text, "Quantity", "Price", "Discount", "GrossAmount", "NetAmount",
           "StoreNo"::text, "POSTerminalNo"::text, "TransactionNo"::text, "EODID"::text, "SyncedAtUtc",
           count(*) over()
    from public."ExpenseEntryHeader"
    where (p_period is distinct from 'month' or ("Date" >= v_month_start and "Date" < v_month_end))
      and (p_period is distinct from 'today' or "Date" = v_today)
      and (
        (p_receipt_no is not null and trim(p_receipt_no) <> '' and "ReceiptNo" = p_receipt_no)
        or (
          (p_receipt_no is null or trim(p_receipt_no) = '')
          and (
            p_search is null or trim(p_search) = ''
            or "ReceiptNo" ilike '%' || p_search || '%'
            or "Description" ilike '%' || p_search || '%'
            or "ExpenseCategory" ilike '%' || p_search || '%'
            or "UserID" ilike '%' || p_search || '%'
            or "Warehouse" ilike '%' || p_search || '%'
          )
        )
      )
    order by "SyncedAtUtc" desc nulls last, "Date" desc nulls last
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_list_expense_entry_lines(text, text, text);
drop function if exists public.admin_list_expense_entry_lines(text, text, text, int, int);

-- p_page/p_page_size (portal-wide pagination): total_count is count(*) over(), computed before
-- LIMIT/OFFSET applies, so the client can compute total pages without a separate count query.
create or replace function public.admin_list_expense_entry_lines(p_admin_username text, p_admin_password text, p_receipt_no text, p_page int default 1, p_page_size int default 50)
returns table(
  receipt_no text,
  line_id text,
  entry_date timestamptz,
  item_code text,
  variation_id text,
  quantity numeric,
  unit_cost numeric,
  total_cost numeric,
  price numeric,
  discount numeric,
  gross_amount numeric,
  net_amount numeric,
  description text,
  user_id text,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "ReceiptNo"::text, "LineID"::text, "EntryDate", "ItemCode"::text, "VariationId"::text,
           "Quantity", "UnitCost", "TotalCost", "Price", "Discount", "GrossAmount", "NetAmount",
           "Description"::text, "UserID"::text,
           count(*) over()
    from public."ExpenseEntryLines"
    where "ReceiptNo" = p_receipt_no
    order by "LineID"
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_expense_entries(text, text, text, text, text, int, int) to anon;
grant execute on function public.admin_list_expense_entry_lines(text, text, text, int, int) to anon;

-- Dashboard "Expense Today" / "Expense This Month" cards (super users only) - fills in the
-- "Total Expense" placeholder card (see the TODO in dashboard.js) now that ExpenseEntryHeader
-- exists. Mirrors admin_get_online_order_financial_summary's Asia/Manila month/day boundary
-- logic (supabase_orders_sync_tables.sql) so "this month"/"today" always agree with the rest of
-- the dashboard regardless of the viewer's own browser timezone.
--
-- Sums "NetAmount" - for Type = 'EXPENSE' TransactionHeader rows, MainForm.WriteSalesTransaction
-- Header sets NetAmount = GrossAmount = Price = the posted expense total (no discount/tax split
-- for this document type), so it's the correct single figure to sum.
--
-- p_warehouse_name: unlike OnlineOrders (which stores a LocationID needing a join against
-- Warehouses), ExpenseEntryHeader.Warehouse already stores the resolved warehouse NAME directly
-- (written by TransferOrderData.GetCurrentWarehouse(...)?.Name at POST time), so this filters
-- straight against it with no join - same session.warehouseName value the portal already passes
-- to every other warehouse-scoped RPC.
--
-- Gated with is_admin_authorized (not the looser is_staff_authorized
-- admin_get_online_order_financial_summary uses) to stay consistent with admin_list_expense_
-- entries/admin_list_expense_entry_lines above, both already super-user-only for this same data.
drop function if exists public.admin_get_expense_entry_summary(text, text, text);

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
      coalesce(sum("NetAmount") filter (where "Date" >= v_month_start and "Date" < v_month_end), 0)::numeric as month_expense,
      count(*) filter (where "Date" >= v_month_start and "Date" < v_month_end)::int as month_expense_count,
      coalesce(sum("NetAmount") filter (where "Date" = v_today), 0)::numeric as today_expense,
      count(*) filter (where "Date" = v_today)::int as today_expense_count
    from public."ExpenseEntryHeader"
    where p_warehouse_name is null or trim(p_warehouse_name) = '' or "Warehouse" = p_warehouse_name;
end;
$$;

grant execute on function public.admin_get_expense_entry_summary(text, text, text) to anon;
