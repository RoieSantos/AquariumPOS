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
-- Access: RLS on with NO policies and no table grants - nobody reads or writes the tables directly.
--   * The POS writes through pos_upsert_tender_declaration (security definer, WRITE-ONLY - returns
--     nothing). Store PCs often have no AQUARIUMPOS_SUPABASE_SERVICE_ROLE_KEY set and push as anon,
--     and a direct table write was refused ("new row violates row-level security policy"); an anon
--     table policy would also have let anyone holding the public key READ the cash data.
--   * The portal reads only through the functions in supabase_tender_deposit_receipts.sql
--     (Super User, or Store Manager for their own store).
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

-- Cashier's reason when the drawer is Short / Over (required by the POS whenever Variance <> 0).
alter table public."TenderDeclarationHeader" add column if not exists "VarianceReason" varchar(255);

create index if not exists "IX_TenderDeclarationHeader_DeclDate" on public."TenderDeclarationHeader" ("DeclDate" desc);

alter table public."TenderDeclarationHeader" enable row level security;
alter table public."TenderDeclarationLines" enable row level security;

-- No direct table access at all (see the header note) - writes go through pos_upsert_tender_declaration.
revoke all on public."TenderDeclarationHeader" from anon, authenticated;
revoke all on public."TenderDeclarationLines" from anon, authenticated;

comment on table public."TenderDeclarationHeader" is 'Posted POS Tender Declarations (end-of-day cash count), one row per Warehouse + EODID. Variance = DeclaredCash - ExpectedCash (negative = Short).';
comment on table public."TenderDeclarationLines" is 'Denominations counted on a posted POS Tender Declaration (copy of local dbo.TenderDeclLines).';

-- ---------------------------------------------------------------------------
-- POS write path (OnlinefunctionsEvents.SyncTenderDeclarationToSupabaseAsync). Write-only: upserts the
-- header and replaces that declaration's lines, returns nothing. p_header / p_lines use the table's
-- own column names as JSON keys.

drop function if exists public.pos_upsert_tender_declaration(jsonb, jsonb);

create or replace function public.pos_upsert_tender_declaration(p_header jsonb, p_lines jsonb default '[]'::jsonb)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  h public."TenderDeclarationHeader";
begin
  h := jsonb_populate_record(null::public."TenderDeclarationHeader", p_header);

  if nullif(trim(coalesce(h."Warehouse", '')), '') is null then
    raise exception 'Warehouse is required.';
  end if;
  if coalesce(h."EODID", '') !~ '^EOD-RS[0-9]{9}$' then
    raise exception 'Invalid EODID.';
  end if;

  insert into public."TenderDeclarationHeader" as t (
    "Warehouse", "EODID", "ReceiptNo", "UserID", "DeclDate", "DeclTime",
    "FloatAmount", "CashSales", "CashIncome", "CashExpense", "ExpectedCash", "DeclaredCash", "Variance", "VarianceReason",
    "AdvanceCollections", "SalesByTender", "FromHistoryUpload", "SyncedAtUtc"
  ) values (
    h."Warehouse", h."EODID", h."ReceiptNo", h."UserID", h."DeclDate", h."DeclTime",
    coalesce(h."FloatAmount", 0), coalesce(h."CashSales", 0), coalesce(h."CashIncome", 0), coalesce(h."CashExpense", 0),
    coalesce(h."ExpectedCash", 0), coalesce(h."DeclaredCash", 0), coalesce(h."Variance", 0), h."VarianceReason",
    coalesce(h."AdvanceCollections", 0), coalesce(h."SalesByTender", '{}'::jsonb), coalesce(h."FromHistoryUpload", false),
    coalesce(h."SyncedAtUtc", now())
  )
  on conflict ("Warehouse", "EODID") do update set
    "ReceiptNo" = excluded."ReceiptNo",
    "UserID" = excluded."UserID",
    "DeclDate" = excluded."DeclDate",
    "DeclTime" = excluded."DeclTime",
    "FloatAmount" = excluded."FloatAmount",
    "CashSales" = excluded."CashSales",
    "CashIncome" = excluded."CashIncome",
    "CashExpense" = excluded."CashExpense",
    "ExpectedCash" = excluded."ExpectedCash",
    "DeclaredCash" = excluded."DeclaredCash",
    "Variance" = excluded."Variance",
    "VarianceReason" = excluded."VarianceReason",
    "AdvanceCollections" = excluded."AdvanceCollections",
    "SalesByTender" = excluded."SalesByTender",
    -- A live post stays "live" even if the history button re-sends it later.
    "FromHistoryUpload" = t."FromHistoryUpload" and excluded."FromHistoryUpload",
    "SyncedAtUtc" = excluded."SyncedAtUtc";

  delete from public."TenderDeclarationLines"
  where "Warehouse" = h."Warehouse" and "EODID" = h."EODID";

  insert into public."TenderDeclarationLines" ("Warehouse", "EODID", "EntryNo", "LineNo", "ReceiptNo", "Denomination", "Qty", "TotalAmount", "SyncedAtUtc")
  select h."Warehouse", h."EODID", l."EntryNo", l."LineNo", l."ReceiptNo", l."Denomination", coalesce(l."Qty", 0), coalesce(l."TotalAmount", 0), coalesce(l."SyncedAtUtc", now())
  from jsonb_populate_recordset(null::public."TenderDeclarationLines", coalesce(p_lines, '[]'::jsonb)) l
  where l."EntryNo" is not null and l."Denomination" is not null;
end;
$$;

revoke all on function public.pos_upsert_tender_declaration(jsonb, jsonb) from public;
grant execute on function public.pos_upsert_tender_declaration(jsonb, jsonb) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Portal read functions (admin_list_tender_declarations / admin_list_tender_declaration_lines) MOVED to
-- supabase_tender_deposit_receipts.sql (Store Manager access + deposit receipts) - run that file after
-- this one. They are not defined here any more so re-running this file can't put back the old,
-- super-user-only versions.

notify pgrst, 'reload schema';
