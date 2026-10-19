-- Supabase/Postgres mirror of posted Tender Declarations (the cashier's end-of-day cash count in the
-- POS - TenderDeclarationForm), per "i want to store the details of tender declaration to the portal".
--
-- Sent by the desktop app right after a declaration posts (OnlinefunctionsEvents.
-- SyncTenderDeclarationToSupabaseAsync), and for past ones via Settings > UPLOAD TENDER DECL HISTORY
-- (UploadAllTenderDeclarationsAsync). Upserted, so re-sending is always safe.
--
--   * TenderDeclarationHeader - one row per declaration: cashier, date, and the cash figures behind
--     the printed receipt's Short/Over (FunctionEvents.GetTenderDeclSummary - same numbers as the paper):
--       ExpectedCash = FloatAmount + CashSales + CashIncome - CashExpense
--       Variance     = DeclaredCash - ExpectedCash   (negative = Short, positive = Over)
--   * TenderDeclarationLines - one row per denomination counted (local dbo.TenderDeclLines).
--
-- Keyed by Warehouse + EODID: the EODID (EOD-RS000000001...) is a per-POS-machine running number, so
-- two stores can have the same one.
--
-- Same access model as Expenses (supabase_expense_entry_tables.sql): RLS on with no policies, the
-- desktop writes with its secret key, and the portal reads only through the super-user-only
-- (is_admin_authorized) functions below.
--
-- Safe to re-run.

create table if not exists public."TenderDeclarationHeader" (
    "Warehouse" varchar(200) not null,
    "EODID" varchar(50) not null,
    "ReceiptNo" varchar(50),
    "UserID" varchar(100),
    "DeclDate" date,
    "DeclTime" varchar(20),
    "FloatAmount" numeric(18, 2) not null default 0,
    "CashSales" numeric(18, 2) not null default 0,
    "CashIncome" numeric(18, 2) not null default 0,
    "CashExpense" numeric(18, 2) not null default 0,
    "ExpectedCash" numeric(18, 2) not null default 0,
    "DeclaredCash" numeric(18, 2) not null default 0,
    "Variance" numeric(18, 2) not null default 0,
    "AdvanceCollections" numeric(18, 2) not null default 0,
    "SalesByTender" jsonb not null default '{}'::jsonb,
    "FromHistoryUpload" boolean not null default false,
    "SyncedAtUtc" timestamptz,
    constraint "PK_TenderDeclarationHeader" primary key ("Warehouse", "EODID")
);

create table if not exists public."TenderDeclarationLines" (
    "Warehouse" varchar(200) not null,
    "EODID" varchar(50) not null,
    "EntryNo" int not null,
    "LineNo" int,
    "ReceiptNo" varchar(50),
    "Denomination" numeric(18, 2) not null,
    "Qty" int not null default 0,
    "TotalAmount" numeric(18, 2) not null default 0,
    "SyncedAtUtc" timestamptz,
    constraint "PK_TenderDeclarationLines" primary key ("Warehouse", "EODID", "EntryNo"),
    constraint "FK_TenderDeclarationLines_Header" foreign key ("Warehouse", "EODID")
        references public."TenderDeclarationHeader" ("Warehouse", "EODID") on delete cascade
);

create index if not exists "IX_TenderDeclarationHeader_DeclDate" on public."TenderDeclarationHeader" ("DeclDate" desc);

alter table public."TenderDeclarationHeader" enable row level security;
alter table public."TenderDeclarationLines" enable row level security;

-- Same grants as the Expense Entry sync tables: RLS stays on with no policies, so only the
-- desktop's secret key (bypasses RLS) can actually read or write rows.
revoke all on public."TenderDeclarationHeader" from anon, authenticated;
revoke all on public."TenderDeclarationLines" from anon, authenticated;
grant select, insert, update on public."TenderDeclarationHeader" to anon, authenticated;
grant select, insert, update on public."TenderDeclarationLines" to anon, authenticated;

comment on table public."TenderDeclarationHeader" is 'Posted POS Tender Declarations (end-of-day cash count), one row per Warehouse + EODID. Variance = DeclaredCash - ExpectedCash (negative = Short).';
comment on table public."TenderDeclarationLines" is 'Denominations counted on a posted POS Tender Declaration (copy of local dbo.TenderDeclLines).';

-- ---------------------------------------------------------------------------
-- Portal: list (super users only).
-- p_result: 'short' / 'over' / 'balanced' filter on Variance. p_from / p_to: DeclDate range.

drop function if exists public.admin_list_tender_declarations(text, text, text, text, date, date, text, int, int);

create or replace function public.admin_list_tender_declarations(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_warehouse text default null,
  p_from date default null,
  p_to date default null,
  p_result text default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  warehouse text,
  eod_id text,
  receipt_no text,
  user_id text,
  decl_date date,
  decl_time text,
  float_amount numeric,
  cash_sales numeric,
  cash_income numeric,
  cash_expense numeric,
  expected_cash numeric,
  declared_cash numeric,
  variance numeric,
  advance_collections numeric,
  sales_by_tender jsonb,
  from_history_upload boolean,
  synced_at_utc timestamptz,
  total_count bigint,
  total_short numeric,
  total_over numeric
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_warehouse text := nullif(trim(coalesce(p_warehouse, '')), '');
  v_result text := lower(nullif(trim(coalesce(p_result, '')), ''));
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      h."Warehouse"::text, h."EODID"::text, h."ReceiptNo"::text, h."UserID"::text, h."DeclDate", h."DeclTime"::text,
      h."FloatAmount", h."CashSales", h."CashIncome", h."CashExpense", h."ExpectedCash", h."DeclaredCash",
      h."Variance", h."AdvanceCollections", h."SalesByTender", h."FromHistoryUpload", h."SyncedAtUtc",
      count(*) over(),
      coalesce(sum(case when h."Variance" < 0 then -h."Variance" else 0 end) over(), 0),
      coalesce(sum(case when h."Variance" > 0 then h."Variance" else 0 end) over(), 0)
    from public."TenderDeclarationHeader" h
    where (v_warehouse is null or h."Warehouse" = v_warehouse)
      and (p_from is null or h."DeclDate" >= p_from)
      and (p_to is null or h."DeclDate" <= p_to)
      and (
        v_result is null
        or (v_result = 'short' and h."Variance" < 0)
        or (v_result = 'over' and h."Variance" > 0)
        or (v_result = 'balanced' and h."Variance" = 0)
      )
      and (
        v_search is null
        or h."EODID" ilike '%' || v_search || '%'
        or h."ReceiptNo" ilike '%' || v_search || '%'
        or h."UserID" ilike '%' || v_search || '%'
        or h."Warehouse" ilike '%' || v_search || '%'
      )
    order by h."DeclDate" desc nulls last, h."EODID" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- Portal: one declaration's denomination lines (super users only).

drop function if exists public.admin_list_tender_declaration_lines(text, text, text, text);

create or replace function public.admin_list_tender_declaration_lines(
  p_admin_username text,
  p_admin_password text,
  p_warehouse text,
  p_eod_id text
)
returns table(
  entry_no int,
  line_no int,
  denomination numeric,
  qty int,
  total_amount numeric
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
    select l."EntryNo", l."LineNo", l."Denomination", l."Qty", l."TotalAmount"
    from public."TenderDeclarationLines" l
    where l."Warehouse" = p_warehouse and l."EODID" = p_eod_id
    order by l."Denomination" desc;
end;
$$;

grant execute on function public.admin_list_tender_declarations(text, text, text, text, date, date, text, int, int) to anon;
grant execute on function public.admin_list_tender_declaration_lines(text, text, text, text) to anon;

notify pgrst, 'reload schema';
