-- Payroll Ledger: a permanent, detailed financial trail generated automatically the moment a
-- payroll run is finalized (see supabase_payroll_tables.sql for the run/line/line-item schema this
-- builds on). Per "so in every payrun can you do posting and ledger entries? this will track
-- everything in detailed" - "posting" is folded into the existing Finalize action (a run already
-- becomes immutable at that point - see admin_finalize_payroll_run's edit-guards on every
-- admin_update_payroll_run_line_*/admin_add_payroll_line_item/admin_delete_payroll_line_item RPC),
-- rather than adding a third run status. This is deliberately self-contained within the Payroll
-- module (Supabase) - it does NOT post anything into the desktop app's own SQL Server accounting
-- tables (TransactionHeader/ItemLedgerEntry, the ones the local POS commission feature uses); those
-- are two separate databases that don't otherwise exchange financial data.
--
-- One row is written per component of every employee's line on the run - Base Pay, each
-- Addition/Deduction line item, and Net Pay - each carrying its own snapshot of the run's period
-- info and the employee's display name at posting time, so this table can be queried/reported on
-- by itself (by date range, by employee, by run) without joining back to PayrollRuns/PayrollRunLines
-- every time, and without those rows ever changing even if something referenced later did (e.g. an
-- employee's DisplayName changes in StaffUsers afterward - the ledger keeps what was true at the
-- moment of posting, same reasoning as recompute_payroll_run_line freezing BasePay/NetPay on the
-- run's own lines).
--
-- Run this in the Supabase SQL Editor AFTER supabase_payroll_tables.sql.

create table if not exists public."PayrollLedgerEntries" (
    "LedgerID" uuid primary key default gen_random_uuid(),
    "RunID" uuid not null references public."PayrollRuns"("RunID") on delete cascade,
    "LineID" uuid not null references public."PayrollRunLines"("LineID") on delete cascade,
    "Username" varchar(100) not null references public."StaffUsers"("Username"),
    "DisplayName" varchar(200),
    "PayCycle" varchar(20) not null,
    "PeriodStart" date not null,
    "PeriodEnd" date not null,
    "PayDate" date,
    "EntryType" varchar(20) not null check ("EntryType" in ('BasePay', 'Addition', 'Deduction', 'NetPay')),
    "Label" varchar(200) not null,
    "Amount" numeric(18, 2) not null,
    "SourceItemID" uuid references public."PayrollRunLineItems"("ItemID") on delete set null,
    "PostedBy" varchar(100) not null,
    "PostedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."PayrollLedgerEntries" enable row level security;
revoke all on public."PayrollLedgerEntries" from anon, authenticated;

create index if not exists "IX_PayrollLedgerEntries_RunID" on public."PayrollLedgerEntries" ("RunID");
create index if not exists "IX_PayrollLedgerEntries_Username" on public."PayrollLedgerEntries" ("Username");
create index if not exists "IX_PayrollLedgerEntries_PeriodStart" on public."PayrollLedgerEntries" ("PeriodStart");

comment on table public."PayrollLedgerEntries" is 'Immutable detailed ledger written once per payroll run at Finalize time - one row per Base Pay/Addition/Deduction/Net Pay component per employee.';

-- ---------------------------------------------------------------------------
-- admin_finalize_payroll_run: same signature/behavior as before (supabase_payroll_tables.sql), plus
-- posting PayrollLedgerEntries rows the moment the run actually transitions Draft -> Finalized.
-- Guarded two ways against double-posting on a repeat call (e.g. a retried request hitting an
-- already-finalized run): v_updated (the UPDATE's own row count - 0 if the row wasn't Draft) and a
-- belt-and-suspenders "no ledger rows already exist for this run" check.

drop function if exists public.admin_finalize_payroll_run(text, text, uuid);

create or replace function public.admin_finalize_payroll_run(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_updated int;
  v_pay_cycle text;
  v_period_start date;
  v_period_end date;
  v_pay_date date;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if not exists (select 1 from public."PayrollRuns" where "RunID" = p_run_id) then
    return query select false, 'Payroll run not found.'::text;
    return;
  end if;

  update public."PayrollRuns"
    set "Status" = 'Finalized', "FinalizedBy" = p_admin_username, "FinalizedAtUtc" = timezone('utc', now())
    where "RunID" = p_run_id and "Status" = 'Draft'
  returning "PayCycle", "PeriodStart", "PeriodEnd", "PayDate"
    into v_pay_cycle, v_period_start, v_period_end, v_pay_date;

  get diagnostics v_updated = row_count;

  if v_updated > 0 and not exists (select 1 from public."PayrollLedgerEntries" where "RunID" = p_run_id) then
    insert into public."PayrollLedgerEntries"
      ("RunID", "LineID", "Username", "DisplayName", "PayCycle", "PeriodStart", "PeriodEnd", "PayDate",
       "EntryType", "Label", "Amount", "SourceItemID", "PostedBy")
    select l."RunID", l."LineID", l."Username", l."DisplayName", v_pay_cycle, v_period_start, v_period_end, v_pay_date,
           'BasePay', 'Base Pay', l."BasePay", null, p_admin_username
    from public."PayrollRunLines" l
    where l."RunID" = p_run_id;

    insert into public."PayrollLedgerEntries"
      ("RunID", "LineID", "Username", "DisplayName", "PayCycle", "PeriodStart", "PeriodEnd", "PayDate",
       "EntryType", "Label", "Amount", "SourceItemID", "PostedBy")
    select l."RunID", l."LineID", l."Username", l."DisplayName", v_pay_cycle, v_period_start, v_period_end, v_pay_date,
           i."ItemType", i."Label", i."Amount", i."ItemID", p_admin_username
    from public."PayrollRunLines" l
    join public."PayrollRunLineItems" i on i."LineID" = l."LineID"
    where l."RunID" = p_run_id;

    insert into public."PayrollLedgerEntries"
      ("RunID", "LineID", "Username", "DisplayName", "PayCycle", "PeriodStart", "PeriodEnd", "PayDate",
       "EntryType", "Label", "Amount", "SourceItemID", "PostedBy")
    select l."RunID", l."LineID", l."Username", l."DisplayName", v_pay_cycle, v_period_start, v_period_end, v_pay_date,
           'NetPay', 'Net Pay', l."NetPay", null, p_admin_username
    from public."PayrollRunLines" l
    where l."RunID" = p_run_id;
  end if;

  return query select true, 'Payroll run finalized.'::text;
end;
$$;

grant execute on function public.admin_finalize_payroll_run(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_ledger_entries: filterable read of the ledger - by run (for the Payroll Run
-- detail page's ledger section), by employee and/or period range (for the standalone Payroll
-- Ledger report page), or unfiltered for a full dump. All filters are optional and combine with AND.
-- The period filter is an OVERLAP test (PeriodEnd >= p_period_start AND PeriodStart <= p_period_end),
-- not full-containment - required because Semi-Monthly cutoffs here can span two calendar months
-- (e.g. the 26th-10th cutoff in supabase_payroll_tables.sql's PayrollCutoffSettings seed), so a
-- "this month" window must still surface a run whose period only partly falls inside it.

drop function if exists public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date);

create or replace function public.admin_list_payroll_ledger_entries(
  p_admin_username text,
  p_admin_password text,
  p_run_id uuid default null,
  p_username text default null,
  p_period_start date default null,
  p_period_end date default null
)
returns table(
  ledger_id uuid,
  run_id uuid,
  line_id uuid,
  username text,
  display_name text,
  pay_cycle text,
  period_start date,
  period_end date,
  pay_date date,
  entry_type text,
  label text,
  amount numeric,
  posted_by text,
  posted_at_utc timestamptz
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
    select "LedgerID", "RunID", "LineID", "Username"::text, "DisplayName"::text, "PayCycle"::text,
           "PeriodStart", "PeriodEnd", "PayDate", "EntryType"::text, "Label"::text, "Amount",
           "PostedBy"::text, "PostedAtUtc"
    from public."PayrollLedgerEntries"
    where (p_run_id is null or "RunID" = p_run_id)
      and (p_username is null or "Username" = p_username)
      and (p_period_start is null or "PeriodEnd" >= p_period_start)
      and (p_period_end is null or "PeriodStart" <= p_period_end)
    order by "PeriodStart" desc, "DisplayName", case "EntryType" when 'BasePay' then 0 when 'Addition' then 1 when 'Deduction' then 2 else 3 end;
end;
$$;

grant execute on function public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date) to anon;
