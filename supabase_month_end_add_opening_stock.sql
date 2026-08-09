-- Postgres/Supabase version - adds the Opening Stock / Variance / Shrinkage %
-- columns to an existing public."MonthEndLines" table.
-- Run this in the Supabase SQL Editor (NOT SQL Server Management Studio -
-- that script is sql_month_end_opening_stock.sql, which uses T-SQL syntax
-- that Postgres cannot parse).
--
-- Safe to run multiple times - "ADD COLUMN IF NOT EXISTS" is a no-op if the
-- column already exists (e.g. if the table was created fresh from the
-- current supabase_month_end.sql, which already includes these columns).

ALTER TABLE public."MonthEndLines"
    ADD COLUMN IF NOT EXISTS "OpeningStock" numeric(18, 2) NOT NULL DEFAULT 0;

ALTER TABLE public."MonthEndLines"
    ADD COLUMN IF NOT EXISTS "Variance" numeric(18, 2);

ALTER TABLE public."MonthEndLines"
    ADD COLUMN IF NOT EXISTS "ShrinkagePercent" numeric(9, 4);

comment on column public."MonthEndLines"."OpeningStock" is 'Prior month''s closing stock, carried over from the previously posted Month End for this Report Key.';
comment on column public."MonthEndLines"."Variance" is 'PhysicalQtyOnHand - QtyOnHand.';
comment on column public."MonthEndLines"."ShrinkagePercent" is '(Variance / QtyOnHand) * 100.';
