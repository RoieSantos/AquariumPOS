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
--   * The portal reads only through the super-user-only (is_admin_authorized) functions below.
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
  variance_reason text,
  advance_collections numeric,
  sales_by_tender jsonb,
  from_history_upload boolean,
  synced_at_utc timestamptz,
  total_count bigint,
  total_short numeric,
  total_over numeric,
  total_declared numeric
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
      h."Variance", h."VarianceReason"::text, h."AdvanceCollections", h."SalesByTender", h."FromHistoryUpload", h."SyncedAtUtc",
      count(*) over(),
      coalesce(sum(case when h."Variance" < 0 then -h."Variance" else 0 end) over(), 0),
      coalesce(sum(case when h."Variance" > 0 then h."Variance" else 0 end) over(), 0),
      coalesce(sum(h."DeclaredCash") over(), 0)
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
        or h."VarianceReason" ilike '%' || v_search || '%'
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
