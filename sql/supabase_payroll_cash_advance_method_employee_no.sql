-- Adds a Method (Cash/Digital) to Cash Advances, same field/values as PayrollFundingLedger's
-- Method (supabase_payroll_funding_ledger.sql) - lets the officer record whether an advance was
-- handed over in cash or sent via GCash. Also surfaces Employee No. on the Cash Advances list -
-- pulled read-only from StaffUsers."EmployeeNo" (supabase_payroll_employee_no.sql), not a new
-- field to fill in twice.
--
-- Run this AFTER supabase_payroll_cash_advance_ledger_posting.sql.

alter table public."PayrollCashAdvances"
    add column if not exists "Method" varchar(20) not null default 'Cash';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'CK_PayrollCashAdvances_Method') then
    alter table public."PayrollCashAdvances"
      add constraint "CK_PayrollCashAdvances_Method" check ("Method" in ('Cash', 'Digital'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- admin_add_cash_advance: p_method appended at the end, default 'Cash' so existing callers
-- (the Timesheets weekly grid's bulk upsert isn't touched by this file) keep working unchanged.

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
-- admin_list_cash_advances: add method and employee_no (joined read-only from StaffUsers).

drop function if exists public.admin_list_cash_advances(text, text, text, text, date, date, int, int);

create or replace function public.admin_list_cash_advances(
  p_admin_username text,
  p_admin_password text,
  p_username text default null,
  p_status text default null,
  p_date_start date default null,
  p_date_end date default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  advance_id uuid,
  username text,
  display_name text,
  employee_no text,
  advance_date date,
  amount numeric,
  method text,
  notes text,
  status text,
  applied_to_run_id uuid,
  applied_at_utc timestamptz,
  created_by text,
  created_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select a."AdvanceID", a."Username"::text, su."DisplayName"::text, su."EmployeeNo"::text, a."AdvanceDate", a."Amount", a."Method"::text, a."Notes"::text,
           a."Status"::text, a."AppliedToRunID", a."AppliedAtUtc", a."CreatedBy"::text, a."CreatedAtUtc",
           count(*) over()
    from public."PayrollCashAdvances" a
    join public."StaffUsers" su on su."Username" = a."Username"
    where (p_username is null or a."Username" = p_username)
      and (p_status is null or a."Status" = p_status)
      and (p_date_start is null or a."AdvanceDate" >= p_date_start)
      and (p_date_end is null or a."AdvanceDate" <= p_date_end)
    order by a."AdvanceDate" desc, a."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_add_cash_advance(text, text, text, date, numeric, text, text) to anon;
grant execute on function public.admin_list_cash_advances(text, text, text, text, date, date, int, int) to anon;
