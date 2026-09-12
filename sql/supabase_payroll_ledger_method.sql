-- Surfaces Method (Cash/Digital) on the Payroll Ledger report for CashAdvance entries - the same
-- Method already captured on PayrollCashAdvances (supabase_payroll_cash_advance_method_employee_no.sql,
-- supabase_payroll_cash_advance_timesheets_method.sql). Null for every other entry type (BasePay/
-- Addition/Deduction/NetPay aren't tied to a single cash/digital release the way a Cash Advance is).
--
-- Run this AFTER supabase_payroll_cash_advance_timesheets_method.sql.

alter table public."PayrollLedgerEntries"
    add column if not exists "Method" varchar(20) null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'CK_PayrollLedgerEntries_Method') then
    alter table public."PayrollLedgerEntries"
      add constraint "CK_PayrollLedgerEntries_Method" check ("Method" is null or "Method" in ('Cash', 'Digital'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- admin_add_cash_advance: same signature - now also stamps Method onto the CashAdvance ledger row.

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

  insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Notes", "Method", "CreatedBy")
  values (p_username, p_advance_date, p_amount, nullif(trim(p_notes), ''), coalesce(p_method, 'Cash'), p_admin_username)
  returning "AdvanceID" into v_advance_id;

  insert into public."PayrollLedgerEntries"
    ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "SourceAdvanceID", "PostedBy")
  values (p_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', p_amount, coalesce(p_method, 'Cash'), v_advance_id, p_admin_username);

  return query select true, 'Cash advance logged.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_upsert_cash_advances_bulk: same signature - Method now also stamped/kept in sync on the
-- ledger row, same treatment as Amount.

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
      else
        insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Method", "CreatedBy")
        values (v_username, p_advance_date, v_amount, v_method, p_admin_username)
        returning "AdvanceID" into v_new_id;

        insert into public."PayrollLedgerEntries"
          ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "SourceAdvanceID", "PostedBy")
        values (v_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', v_amount, v_method, v_new_id, p_admin_username);
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
-- admin_list_payroll_ledger_entries: add method to the report output.

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
  method text,
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
           "PeriodStart", "PeriodEnd", "PayDate", "EntryType"::text, "Label"::text, "Amount", "Method"::text,
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

grant execute on function public.admin_add_cash_advance(text, text, text, date, numeric, text, text) to anon;
grant execute on function public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb) to anon;
grant execute on function public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date) to anon;
