-- Makes a logged Cash Advance actually move Cash on Hand / Digital on Hand, same as a Funding
-- entry or a Finalize payout does. Per: "once the payroll ledger has been inserted or logged...
-- isnt it we need to adjust the cash on hand and digital gcash on hand? if the cashadvance has
-- been saved/posted the cash or digital should be deducted."
--
-- Gap this closes: admin_add_cash_advance / admin_upsert_cash_advances_bulk (see
-- supabase_payroll_ledger_method.sql) already post a "CashAdvance" row to PayrollLedgerEntries
-- (the detailed trail) and capture Method there, but neither ever touched PayrollFundingLedger
-- (the running Cash/Digital balance behind payroll_fund_balance() - see
-- supabase_payroll_funding_ledger.sql) - so cash physically handed out as an advance kept reading
-- as still "on hand" until the run it eventually gets deducted from is Finalized, weeks later.
--
-- No double-counting at Finalize: admin_finalize_payroll_run's Payout amount is driven off each
-- run line's NetPay, which already has the advance subtracted from it (auto-applied as a
-- Deduction line item when the run was created - see admin_create_payroll_run in
-- supabase_payroll_cash_advances.sql). So Advance-time Payout (the advance amount) + Finalize-time
-- Payout (NetPay, already net of that advance) sums to exactly the employee's original pay - the
-- same total that would have posted if no advance had ever been taken.
--
-- SourceAdvanceID mirrors the same column already added to PayrollLedgerEntries
-- (supabase_payroll_cash_advance_ledger_posting.sql) so an Outstanding advance's edit/delete can
-- find-and-sync its funding row the same way it already does for the ledger row.
--
-- Run this AFTER supabase_payroll_ledger_method.sql.

alter table public."PayrollFundingLedger"
    add column if not exists "SourceAdvanceID" uuid references public."PayrollCashAdvances"("AdvanceID") on delete set null;

create index if not exists "IX_PayrollFundingLedger_SourceAdvanceID" on public."PayrollFundingLedger" ("SourceAdvanceID");

-- ---------------------------------------------------------------------------
-- admin_add_cash_advance: same signature - now also posts a Payout to PayrollFundingLedger.

create or replace function public.admin_add_cash_advance(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_advance_date date,
  p_amount numeric,
  p_notes text default null,
  p_method text default 'Cash'
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_advance_id uuid;
  v_display_name text;
  v_method text;
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

  if coalesce(p_method, 'Cash') not in ('Cash', 'Digital') then
    return query select false, 'Method must be Cash or Digital.'::text;
    return;
  end if;
  v_method := coalesce(p_method, 'Cash');

  insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Notes", "Method", "CreatedBy")
  values (p_username, p_advance_date, p_amount, nullif(trim(p_notes), ''), v_method, p_admin_username)
  returning "AdvanceID" into v_advance_id;

  insert into public."PayrollLedgerEntries"
    ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "SourceAdvanceID", "PostedBy")
  values (p_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', p_amount, v_method, v_advance_id, p_admin_username);

  insert into public."PayrollFundingLedger" ("EntryType", "Method", "Amount", "Notes", "SourceAdvanceID", "PostedBy")
  values ('Payout', v_method, p_amount, 'Cash advance - ' || v_display_name, v_advance_id, p_admin_username);

  return query select true, 'Cash advance logged.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_delete_cash_advance: same signature - now also removes the linked PayrollFundingLedger
-- Payout row (only reachable while Status = 'Outstanding', same guard as the ledger row's delete).

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

  delete from public."PayrollFundingLedger" where "SourceAdvanceID" = p_advance_id;
  delete from public."PayrollLedgerEntries" where "SourceAdvanceID" = p_advance_id;
  delete from public."PayrollCashAdvances" where "AdvanceID" = p_advance_id;

  return query select true, 'Cash advance deleted.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_upsert_cash_advances_bulk: same signature - keeps a linked PayrollFundingLedger Payout row
-- in sync the same way it already keeps the PayrollLedgerEntries row in sync (insert/update/delete
-- mirrored across all three tables).

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
  v_method text;
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
    v_method := v_entry->>'method';
    if coalesce(v_method, '') not in ('Cash', 'Digital') then
      v_method := 'Cash';
    end if;

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
        update public."PayrollCashAdvances" set "Amount" = v_amount, "Method" = v_method where "AdvanceID" = v_existing_id;
        update public."PayrollLedgerEntries" set "Amount" = v_amount, "Method" = v_method where "SourceAdvanceID" = v_existing_id;
        update public."PayrollFundingLedger" set "Amount" = v_amount, "Method" = v_method where "SourceAdvanceID" = v_existing_id;
      else
        insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Method", "CreatedBy")
        values (v_username, p_advance_date, v_amount, v_method, p_admin_username)
        returning "AdvanceID" into v_new_id;

        insert into public."PayrollLedgerEntries"
          ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "SourceAdvanceID", "PostedBy")
        values (v_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', v_amount, v_method, v_new_id, p_admin_username);

        insert into public."PayrollFundingLedger" ("EntryType", "Method", "Amount", "Notes", "SourceAdvanceID", "PostedBy")
        values ('Payout', v_method, v_amount, 'Cash advance - ' || v_display_name, v_new_id, p_admin_username);
      end if;
    else
      if v_existing_id is not null then
        delete from public."PayrollFundingLedger" where "SourceAdvanceID" = v_existing_id;
        delete from public."PayrollLedgerEntries" where "SourceAdvanceID" = v_existing_id;
        delete from public."PayrollCashAdvances" where "AdvanceID" = v_existing_id;
      end if;
    end if;
  end loop;

  return query select true, 'Cash advances saved.'::text;
end;
$$;

grant execute on function public.admin_add_cash_advance(text, text, text, date, numeric, text, text) to anon;
grant execute on function public.admin_delete_cash_advance(text, text, uuid) to anon;
grant execute on function public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb) to anon;
