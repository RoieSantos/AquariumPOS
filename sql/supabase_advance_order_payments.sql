-- Per "possible we show the tender type too on today's advance orders" - the POS never pushed
-- advance-order payments (dbo.TransPaymentEntry) to Supabase, so the portal had no tender data
-- for them. This adds:
--   1. public."AdvanceOrderPayments" - the POS (OnlinefunctionsEvents.SyncAdvanceOrderPayments...)
--      now uploads every TransPaymentEntry row whose ReceiptNo matches an advance order (same rule
--      as the POS EOD report's "ADV ORDER COLLECTIONS"), i.e. downpayments AND later balance
--      payments, each tagged with the advance order's TransactionNo and the POS's warehouse.
--   2. admin_get_dashboard_daily_advance_tender() - feeds the "Collected today · by tender" split
--      under the Dashboard's "Today's Advance Orders" card: advance-order payments dated today
--      (POS local date = Manila), grouped by tender, for any advance order (not only ones placed
--      today - a balance paid today on an older order counts too, like the EOD report).
--
-- Run AFTER supabase_dashboard_daily_advance_orders.sql. Needs the updated POS build to start
-- filling the table (older POS installs simply don't push payments - the split stays hidden).
-- Safe to re-run.

create table if not exists public."AdvanceOrderPayments" (
    "AdvanceTransactionNo" varchar(100) not null,  -- AdvanceOrders."TransactionNo"
    "PaymentTransactionNo" varchar(100) not null,  -- TransPaymentEntry.TransactionNo
    "TenderTypeCode" varchar(50) not null,
    "LineNo" varchar(50) not null,
    "ReceiptNo" varchar(100),
    "Description" varchar(500),
    "Amount" numeric(18, 2),
    "UserID" varchar(100),
    "Date" date,
    "Time" varchar(20),
    "Warehouse" text,
    "SyncedAtUtc" timestamptz,
    constraint "PK_AdvanceOrderPayments"
      primary key ("AdvanceTransactionNo", "PaymentTransactionNo", "TenderTypeCode", "LineNo")
);

create index if not exists "IX_AdvanceOrderPayments_Date" on public."AdvanceOrderPayments" ("Date");

-- Same direct anon access the POS desktop sync already has on AdvanceOrders/AdvanceOrderLines
-- (supabase_allow_anon_order_sync.sql).
alter table public."AdvanceOrderPayments" enable row level security;
grant select, insert, update on public."AdvanceOrderPayments" to anon;
drop policy if exists "allow_anon_desktop_sync" on public."AdvanceOrderPayments";
create policy "allow_anon_desktop_sync" on public."AdvanceOrderPayments"
  for all to anon using (true) with check (true);

drop function if exists public.admin_get_dashboard_daily_advance_tender(text, text, text);

create or replace function public.admin_get_dashboard_daily_advance_tender(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_name text default null
)
returns table(
  method_name text,
  amount numeric,
  payment_count int
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_wh text := nullif(trim(coalesce(p_warehouse_name, '')), '');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select coalesce(nullif(upper(trim(p."TenderTypeCode")), ''), '(No tender)')::text,
           coalesce(sum(p."Amount"), 0)::numeric,
           count(*)::int
    from public."AdvanceOrderPayments" p
    left join public."AdvanceOrders" a on a."TransactionNo" = p."AdvanceTransactionNo"
    where p."Date" = v_today
      and (v_wh is null or coalesce(a."Warehouse", p."Warehouse") = v_wh)
    group by 1
    order by 2 desc;
end;
$$;

grant execute on function public.admin_get_dashboard_daily_advance_tender(text, text, text) to anon;
