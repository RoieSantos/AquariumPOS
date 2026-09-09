-- Postgres/Supabase version of the Expense Report tables.
-- Run this in the Supabase SQL Editor (NOT SQL Server Management Studio -
-- the T-SQL version is sql_expense_report_tables.sql, which uses
-- IF OBJECT_ID(...)/BEGIN...END syntax that Postgres cannot parse).
--
-- Column names mirror the C# model (Category, Description, UserId, etc.)
-- following the same convention used in supabase_month_end.sql.

create table if not exists public."ExpenseReportHeader" (
    "DocumentNo" varchar(50) not null primary key,
    "GeneratedDate" timestamptz not null,
    "FromDate" date not null,
    "ToDate" date not null,
    "WarehouseName" varchar(200),
    "GeneratedBy" varchar(100),
    "TotalLines" integer not null default 0,
    "GrandTotal" numeric(18, 2) not null default 0,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

create table if not exists public."ExpenseReportLines" (
    "DocumentNo" varchar(50) not null references public."ExpenseReportHeader" ("DocumentNo"),
    "LineNo" integer not null,
    "Category" varchar(100),
    "Description" varchar(500),
    "UserId" varchar(100),
    "TransactionDate" date,
    "TransactionTime" varchar(20),
    "Quantity" numeric(18, 2) not null default 0,
    "Amount" numeric(18, 2) not null default 0,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now()),
    primary key ("DocumentNo", "LineNo")
);

create index if not exists "IX_ExpenseReportLines_Category"
    on public."ExpenseReportLines" ("Category");

comment on table public."ExpenseReportHeader" is 'Supabase copy of the AquariumPOS local dbo.ExpenseReportHeader table (Expense Report batches).';
comment on table public."ExpenseReportLines" is 'Supabase copy of the AquariumPOS local dbo.ExpenseReportLines table (Expense Report line detail).';
comment on column public."ExpenseReportHeader"."DocumentNo" is 'Primary key, matches local [No.] / C# DocumentNo.';
comment on column public."ExpenseReportHeader"."FromDate" is 'Start of the report date coverage.';
comment on column public."ExpenseReportHeader"."ToDate" is 'End of the report date coverage.';
comment on column public."ExpenseReportLines"."DocumentNo" is 'Foreign key to ExpenseReportHeader.DocumentNo.';
