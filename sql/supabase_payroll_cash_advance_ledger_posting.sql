-- Posts a Cash Advance to PayrollLedgerEntries the moment it's logged, for tracking (audit trail
-- of money released) - not just when it's later auto-deducted at Finalize time. PayrollLedgerEntries
-- previously only ever held rows for a finalized run (RunID/PayCycle/Period were required, not-null
-- fields), but a Cash Advance is released before any run exists, so those columns are relaxed to
-- nullable here and a new EntryType='CashAdvance' is added.
--
-- A CashAdvance ledger row and the eventual run Deduction ledger row (posted separately at
-- Finalize, unchanged) are two distinct events kept as two separate rows - cash left the till when
-- the advance was released, and the employee's wage was reduced later when the run finalized. Both
-- are worth seeing on the Payroll Ledger report.
--
-- While a Cash Advance is still Outstanding (not yet applied to a run), its ledger row is kept in
-- sync: editing the amount updates the ledger row's Amount, and deleting the advance deletes its
-- ledger row too - same "still a draft, not yet final" treatment PayrollRunLines gets pre-Finalize.
-- Once Applied, the advance (and its CashAdvance ledger row) are left alone - the historical record
-- of what was actually released stays exactly as it was, matching the ledger's whole purpose.
--
-- Run this AFTER supabase_payroll_cash_advances_bulk_entry.sql.

alter table public."PayrollLedgerEntries" alter column "RunID" drop not null;
alter table public."PayrollLedgerEntries" alter column "LineID" drop not null;
alter table public."PayrollLedgerEntries" alter column "PayCycle" drop not null;
alter table public."PayrollLedgerEntries" alter column "PeriodStart" drop not null;
alter table public."PayrollLedgerEntries" alter column "PeriodEnd" drop not null;

alter table public."PayrollLedgerEntries"
    add column if not exists "SourceAdvanceID" uuid references public."PayrollCashAdvances"("AdvanceID") on delete set null;

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'PayrollLedgerEntries_EntryType_check') then
    alter table public."PayrollLedgerEntries" drop constraint "PayrollLedgerEntries_EntryType_check";
  end if;
  if not exists (select 1 from pg_constraint where conname = 'CK_PayrollLedgerEntries_EntryType') then
    alter table public."PayrollLedgerEntries"
      add constraint "CK_PayrollLedgerEntries_EntryType" check ("EntryType" in ('BasePay', 'Addition', 'Deduction', 'NetPay', 'CashAdvance'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- admin_add_cash_advance: same signature - now also posts the CashAdvance ledger row.

create or replace function public.admin_add_cash_advance(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_advance_date date,
  p_amount numeric,
  p_notes text default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_advance_id uuid;
  v_display_name text;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_username is null or trim(p_username) = '' then
    return query select false, 'Employee is required.'::text;
    return;
  end if;

  select "DisplayName" into v_display_name from public."StaffUsers" where "Username" = p_username;
  if not found then
    return query select false, 'That employee no longer exists.'::text;
    return;
  end if;

  if p_advance_date is null then
    return query select false, 'Advance date is required.'::text;
    return;
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return query select false, 'Amount must be greater than zero.'::text;
    return;
  end if;

  insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Notes", "CreatedBy")
  values (p_username, p_advance_date, p_amount, nullif(trim(p_notes), ''), p_admin_username)
  returning "AdvanceID" into v_advance_id;

  -- PeriodStart/PeriodEnd both set to the advance date (a one-day "period") so the Payroll Ledger
  -- report's period-range filter still catches this row like any other, even though no actual pay
  -- cycle/run is involved yet.
  insert into public."PayrollLedgerEntries"
    ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "SourceAdvanceID", "PostedBy")
  values (p_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', p_amount, v_advance_id, p_admin_username);

  return query select true, 'Cash advance logged.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_delete_cash_advance: same signature - now also removes the CashAdvance ledger row.

create or replace function public.admin_delete_cash_advance(p_admin_username text, p_admin_password text, p_advance_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select "Status" into v_status from public."PayrollCashAdvances" where "AdvanceID" = p_advance_id;

  if v_status is null then
    return query select false, 'Cash advance not found.'::text;
    return;
  end if;

  if v_status <> 'Outstanding' then
    return query select false, 'Only an Outstanding cash advance can be deleted - this one is already ' || v_status || '.'::text;
    return;
  end if;

  delete from public."PayrollLedgerEntries" where "SourceAdvanceID" = p_advance_id;
  delete from public."PayrollCashAdvances" where "AdvanceID" = p_advance_id;

  return query select true, 'Cash advance deleted.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_upsert_cash_advances_bulk: same signature - keeps the CashAdvance ledger row in sync with
-- whatever the Timesheets grid does (insert/update/delete), same as the two RPCs above.

create or replace function public.admin_upsert_cash_advances_bulk(
  p_admin_username text,
  p_admin_password text,
  p_advance_date date,
  p_week_start date,
  p_week_end date,
  p_entries jsonb
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_entry jsonb;
  v_username text;
  v_amount numeric;
  v_existing_id uuid;
  v_new_id uuid;
  v_display_name text;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_advance_date is null or p_week_start is null or p_week_end is null then
    return query select false, 'A valid advance date and week range are required.'::text;
    return;
  end if;

  for v_entry in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb))
  loop
    v_username := v_entry->>'username';
    v_amount := nullif(v_entry->>'amount', '')::numeric;

    select "DisplayName" into v_display_name from public."StaffUsers" where "Username" = v_username;
    if not found then
      continue;
    end if;

    select "AdvanceID" into v_existing_id
      from public."PayrollCashAdvances"
      where "Username" = v_username and "Status" = 'Outstanding'
        and "AdvanceDate" between p_week_start and p_week_end
      order by "AdvanceDate"
      limit 1;

    if coalesce(v_amount, 0) > 0 then
      if v_existing_id is not null then
        update public."PayrollCashAdvances" set "Amount" = v_amount where "AdvanceID" = v_existing_id;
        update public."PayrollLedgerEntries" set "Amount" = v_amount where "SourceAdvanceID" = v_existing_id;
      else
        insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "CreatedBy")
        values (v_username, p_advance_date, v_amount, p_admin_username)
        returning "AdvanceID" into v_new_id;

        insert into public."PayrollLedgerEntries"
          ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "SourceAdvanceID", "PostedBy")
        values (v_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', v_amount, v_new_id, p_admin_username);
      end if;
    else
      if v_existing_id is not null then
        delete from public."PayrollLedgerEntries" where "SourceAdvanceID" = v_existing_id;
        delete from public."PayrollCashAdvances" where "AdvanceID" = v_existing_id;
      end if;
    end if;
  end loop;

  return query select true, 'Cash advances saved.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_ledger_entries: add source_advance_id so the UI can tell a CashAdvance row
-- apart from a run-tied one.

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
  source_advance_id uuid,
  posted_by text,
  posted_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "LedgerID", "RunID", "LineID", "Username"::text, "DisplayName"::text, "PayCycle"::text,
           "PeriodStart", "PeriodEnd", "PayDate", "EntryType"::text, "Label"::text, "Amount",
           "SourceAdvanceID", "PostedBy"::text, "PostedAtUtc"
    from public."PayrollLedgerEntries"
    where (p_run_id is null or "RunID" = p_run_id)
      and (p_username is null or "Username" = p_username)
      and (p_period_start is null or "PeriodEnd" >= p_period_start)
      and (p_period_end is null or "PeriodStart" <= p_period_end)
    order by "PeriodStart" desc, "DisplayName",
      case "EntryType" when 'CashAdvance' then 0 when 'BasePay' then 1 when 'Addition' then 2 when 'Deduction' then 3 else 4 end;
end;
$$;

grant execute on function public.admin_add_cash_advance(text, text, text, date, numeric, text) to anon;
grant execute on function public.admin_delete_cash_advance(text, text, uuid) to anon;
grant execute on function public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb) to anon;
grant execute on function public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date) to anon;
