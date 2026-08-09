-- Supabase/Postgres version of the local dbo.MonthEndHeader and dbo.MonthEndLines tables.
-- Column names mirror the C# MonthEndHeader/MonthEndLine model properties (ItemVariantSalesWorksheetData.cs)
-- to reduce mapping work, following the same convention used in supabase_item_serial_tracking.sql.

create table if not exists public."MonthEndHeader" (
    "DocumentNo" varchar(50) not null primary key,
    "WorksheetDocumentNo" varchar(50) not null,
    "WorksheetGeneratedDate" timestamptz,
    "FromDate" date not null,
    "ToDate" date not null,
    "WarehouseName" varchar(200),
    "ItemVariantFilter" varchar(300),
    "WorksheetGeneratedBy" varchar(100),
    "PostedBy" varchar(100),
    "PostedAtUtc" timestamptz not null,
    "TotalLines" integer not null default 0,
    "CloudPatchedLines" integer not null default 0,
    "CloudSkippedLines" integer not null default 0,
    "CloudFailedLines" integer not null default 0,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

create table if not exists public."MonthEndLines" (
    "DocumentNo" varchar(50) not null references public."MonthEndHeader" ("DocumentNo"),
    "LineNo" integer not null,
    "ReportKey" varchar(200),
    "ItemNo" varchar(200),
    "Description" varchar(500),
    "QtyTransferred" numeric(18, 2) not null default 0,
    "LocalSales" numeric(18, 2) not null default 0,
    "OnlineSales" numeric(18, 2) not null default 0,
    "QtyOnHand" numeric(18, 2) not null default 0,
    "PhysicalQtyOnHand" numeric(18, 2),
    "OpeningStock" numeric(18, 2) not null default 0,
    "Variance" numeric(18, 2),
    "ShrinkagePercent" numeric(9, 4),
    "VariationId" varchar(100),
    "CloudWarehouseId" varchar(100),
    "CloudPreviousQtyOnHand" numeric(18, 2),
    "CloudUpdatedQtyOnHand" numeric(18, 2),
    "CloudPatchStatus" varchar(50),
    "CloudPatchMessage" text,
    "SentToOnline" boolean not null default false,
    "LastErrorEndpoint" varchar(500),
    "LastErrorPayload" text,
    "LastErrorMessage" text,
    "ProductId" varchar(100),
    "CreatedAtUtc" timestamptz not null default timezone('utc', now()),
    primary key ("DocumentNo", "LineNo")
);

create index if not exists "IX_MonthEndLines_ItemNo"
    on public."MonthEndLines" ("ItemNo");

create index if not exists "IX_MonthEndLines_VariationId"
    on public."MonthEndLines" ("VariationId");

comment on table public."MonthEndHeader" is 'Supabase copy of the AquariumPOS local dbo.MonthEndHeader table (posted Month End batches).';
comment on table public."MonthEndLines" is 'Supabase copy of the AquariumPOS local dbo.MonthEndLines table (posted Month End line detail).';
comment on column public."MonthEndHeader"."DocumentNo" is 'Primary key, matches local [No.] / C# DocumentNo.';
comment on column public."MonthEndHeader"."WorksheetDocumentNo" is 'Document No. of the source Month End Generation Worksheet.';
comment on column public."MonthEndLines"."DocumentNo" is 'Foreign key to MonthEndHeader.DocumentNo.';
comment on column public."MonthEndLines"."SentToOnline" is 'Whether this line was successfully patched to the cloud inventory.';
comment on column public."MonthEndLines"."OpeningStock" is 'Prior month''s closing stock, carried over from the previously posted Month End for this Report Key.';
comment on column public."MonthEndLines"."Variance" is 'PhysicalQtyOnHand - QtyOnHand.';
comment on column public."MonthEndLines"."ShrinkagePercent" is '(Variance / QtyOnHand) * 100.';
