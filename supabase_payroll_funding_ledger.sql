-- Cash/Digital funding journal, per: "the payroll officer shall receive a cash or digital [float]
-- before he/she can do payroll... I want a portion of like journal style to be able to fill in
-- this cash and digital." Confirmed behavior: if Cash or Digital on Hand is short at Finalize
-- time, finalizing is HARD BLOCKED (not just a warning) until enough funding is logged.
--
-- Deliberately a SEPARATE table from PayrollLedgerEntries (supabase_payroll_ledger.sql), not a new
-- EntryType bolted onto it - every PayrollLedgerEntries row is tied to one employee's line
-- component (BasePay/Addition/Deduction/NetPay); a funding top-up isn't about any employee, it's a
-- company-level cash/digital float movement. PayrollFundingLedger is its own small cash book:
--   - "Funding" rows = the officer logging cash/digital actually received (the "positive
--     adjustment" from the conversation).
--   - "Payout" rows = auto-posted the moment a run is Finalized, one per method, for that run's
--     required Cash/Digital split.
-- Running balance per method = sum(Funding) - sum(Payout). That split is decided by each
-- employee's "PaymentMethod" (StaffUsers, supabase_staff_users_hr_profile_fields.sql) - an
-- employee with PaymentMethod left NULL (not yet set) is treated as Cash by default, since most
-- existing employees predate that field being filled in and defaulting to "unclassified" would
-- make the hard block fire on every run. Payment Method is now also editable from this page's Edit
-- Payroll Profile modal (previously User Setup only), so a Payroll Officer without User Setup
-- access can correct it themselves.
--
-- Run this AFTER supabase_staff_users_hr_profile_fields.sql, supabase_payroll_tables.sql,
-- supabase_payroll_ledger.sql, and supabase_payroll_officer_access.sql (reuses is_payroll_authorized
-- from that file, and replaces its version of admin_finalize_payroll_run/
-- admin_list_payroll_employees/admin_update_payroll_profile).

create table if not exists public."PayrollFundingLedger" (
    "FundingID" uuid primary key default gen_random_uuid(),
    "EntryType" varchar(20) not null check ("EntryType" in ('Funding', 'Payout')),
    "Method" varchar(20) not null check ("Method" in ('Cash', 'Digital')),
    "Amount" numeric(18, 2) not null check ("Amount" > 0),
    "Notes" varchar(500),
    "RunID" uuid references public."PayrollRuns"("RunID") on delete set null,
    "PostedBy" varchar(100) not null,
    "PostedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."PayrollFundingLedger" enable row level security;
revoke all on public."PayrollFundingLedger" from anon, authenticated;

create index if not exists "IX_PayrollFundingLedger_Method" on public."PayrollFundingLedger" ("Method");
create index if not exists "IX_PayrollFundingLedger_RunID" on public."PayrollFundingLedger" ("RunID");

comment on table public."PayrollFundingLedger" is 'Cash/Digital float journal: officer-logged Funding entries (received cash/digital) minus auto-posted Payout entries (one per method, written at Finalize time) = current Cash on Hand / Digital on Hand.';

-- ---------------------------------------------------------------------------
-- payroll_fund_balance: private helper (not granted to anon), current running balance for one
-- method. Used both by the read RPCs below and inside admin_finalize_payroll_run's hard-block check.

create or replace function public.payroll_fund_balance(p_method text)
returns numeric
language sql
security definer
set search_path = public, extensions
as $$
  select coalesce(sum(case when "EntryType" = 'Funding' then "Amount" else -"Amount" end), 0)
  from public."PayrollFundingLedger"
  where "Method" = p_method;
$$;

-- ---------------------------------------------------------------------------
-- admin_get_payroll_fund_balances: current Cash on Hand / Digital on Hand for Payroll Setup's
-- display.

create or replace function public.admin_get_payroll_fund_balances(p_admin_username text, p_admin_password text)
returns table(cash_balance numeric, digital_balance numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query select public.payroll_fund_balance('Cash'), public.payroll_fund_balance('Digital');
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_add_payroll_funding_entry: the officer logs cash/digital actually received.

create or replace function public.admin_add_payroll_funding_entry(
  p_admin_username text,
  p_admin_password text,
  p_method text,
  p_amount numeric,
  p_notes text default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_method is null or p_method not in ('Cash', 'Digital') then
    return query select false, 'Method must be Cash or Digital.'::text;
    return;
  end if;

  if p_amount is null or p_amount <= 0 then
    return query select false, 'Amount must be greater than zero.'::text;
    return;
  end if;

  insert into public."PayrollFundingLedger" ("EntryType", "Method", "Amount", "Notes", "PostedBy")
  values ('Funding', p_method, p_amount, nullif(trim(p_notes), ''), p_admin_username);

  return query select true, 'Funding entry logged.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_funding_entries: the journal view (Funding + Payout rows, newest first).

create or replace function public.admin_list_payroll_funding_entries(p_admin_username text, p_admin_password text, p_page int default 1, p_page_size int default 50)
returns table(
  funding_id uuid,
  entry_type text,
  method text,
  amount numeric,
  notes text,
  run_id uuid,
  posted_by text,
  posted_at_utc timestamptz,
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
    select "FundingID", "EntryType"::text, "Method"::text, "Amount", "Notes"::text, "RunID", "PostedBy"::text, "PostedAtUtc",
           count(*) over()
    from public."PayrollFundingLedger"
    order by "PostedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_get_payroll_run_funding_requirement: lets the Payroll Run page show "this run needs ₱X
-- cash / ₱Y digital, you have ₱A / ₱B" before the officer even attempts Finalize.

create or replace function public.admin_get_payroll_run_funding_requirement(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(cash_required numeric, digital_required numeric, cash_balance numeric, digital_balance numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      coalesce(sum(l."NetPay") filter (where coalesce(su."PaymentMethod", 'Cash') = 'Cash'), 0),
      coalesce(sum(l."NetPay") filter (where coalesce(su."PaymentMethod", 'Cash') = 'Digital'), 0),
      public.payroll_fund_balance('Cash'),
      public.payroll_fund_balance('Digital')
    from public."PayrollRunLines" l
    join public."StaffUsers" su on su."Username" = l."Username"
    where l."RunID" = p_run_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_employees: add payment_method so Payroll Setup can show/edit it.

drop function if exists public.admin_list_payroll_employees(text, text);

create or replace function public.admin_list_payroll_employees(p_admin_username text, p_admin_password text)
returns table(
  username text,
  display_name text,
  is_active boolean,
  pay_cycle text,
  monthly_salary numeric,
  payment_method text
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
    select "Username"::text, "DisplayName"::text, "IsActive", "PayCycle"::text, "MonthlySalary", "PaymentMethod"::text
    from public."StaffUsers"
    order by "DisplayName", "Username";
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_update_payroll_profile: add p_payment_method so a Payroll Officer (who may not have User
-- Setup access) can set/correct which bucket an employee's pay draws from.

drop function if exists public.admin_update_payroll_profile(text, text, text, text, numeric, boolean);

create or replace function public.admin_update_payroll_profile(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_pay_cycle text,
  p_monthly_salary numeric,
  p_is_active boolean default true,
  p_payment_method text default null
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_pay_cycle is not null and p_pay_cycle not in ('SemiMonthly', 'Weekly') then
    return query select false, 'Pay cycle must be Semi-Monthly or Weekly.'::text;
    return;
  end if;

  if p_payment_method is not null and p_payment_method not in ('Cash', 'Digital') then
    return query select false, 'Payment method must be Cash or Digital.'::text;
    return;
  end if;

  if not exists (select 1 from public."StaffUsers" where "Username" = p_username) then
    return query select false, 'That staff login no longer exists.'::text;
    return;
  end if;

  update public."StaffUsers"
    set "PayCycle" = p_pay_cycle,
        "MonthlySalary" = coalesce(p_monthly_salary, 0),
        "IsActive" = coalesce(p_is_active, true),
        "PaymentMethod" = p_payment_method
    where "Username" = p_username;

  return query select true, 'Payroll profile updated.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_finalize_payroll_run: same signature as before, now HARD-BLOCKS finalize if either
-- required total (grouped by each employee's PaymentMethod, defaulting unset to Cash) exceeds the
-- current running balance, and posts one "Payout" row per method to PayrollFundingLedger on
-- success. "for update" on the PayrollRuns row serializes concurrent finalize attempts on the same
-- run (replaces the old "update ... where Status = 'Draft'" race guard).

create or replace function public.admin_finalize_payroll_run(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_pay_cycle text;
  v_period_start date;
  v_period_end date;
  v_pay_date date;
  v_cash_required numeric;
  v_digital_required numeric;
  v_cash_balance numeric;
  v_digital_balance numeric;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select "Status", "PayCycle", "PeriodStart", "PeriodEnd", "PayDate"
    into v_status, v_pay_cycle, v_period_start, v_period_end, v_pay_date
    from public."PayrollRuns"
    where "RunID" = p_run_id
    for update;

  if v_status is null then
    return query select false, 'Payroll run not found.'::text;
    return;
  end if;

  if v_status = 'Finalized' then
    return query select true, 'Payroll run finalized.'::text;
    return;
  end if;

  select coalesce(sum(l."NetPay") filter (where coalesce(su."PaymentMethod", 'Cash') = 'Cash'), 0),
         coalesce(sum(l."NetPay") filter (where coalesce(su."PaymentMethod", 'Cash') = 'Digital'), 0)
    into v_cash_required, v_digital_required
    from public."PayrollRunLines" l
    join public."StaffUsers" su on su."Username" = l."Username"
    where l."RunID" = p_run_id;

  v_cash_balance := public.payroll_fund_balance('Cash');
  v_digital_balance := public.payroll_fund_balance('Digital');

  if v_cash_required > v_cash_balance then
    return query select false,
      ('Insufficient Cash on Hand: need ' || to_char(v_cash_required, 'FM999,999,990.00') ||
       ', have ' || to_char(v_cash_balance, 'FM999,999,990.00') ||
       '. Log a Cash funding entry in Payroll Setup first.')::text;
    return;
  end if;

  if v_digital_required > v_digital_balance then
    return query select false,
      ('Insufficient Digital on Hand: need ' || to_char(v_digital_required, 'FM999,999,990.00') ||
       ', have ' || to_char(v_digital_balance, 'FM999,999,990.00') ||
       '. Log a Digital funding entry in Payroll Setup first.')::text;
    return;
  end if;

  update public."PayrollRuns"
    set "Status" = 'Finalized', "FinalizedBy" = p_admin_username, "FinalizedAtUtc" = timezone('utc', now())
    where "RunID" = p_run_id;

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

  if v_cash_required > 0 then
    insert into public."PayrollFundingLedger" ("EntryType", "Method", "Amount", "Notes", "RunID", "PostedBy")
    values ('Payout', 'Cash', v_cash_required, 'Payroll run payout', p_run_id, p_admin_username);
  end if;

  if v_digital_required > 0 then
    insert into public."PayrollFundingLedger" ("EntryType", "Method", "Amount", "Notes", "RunID", "PostedBy")
    values ('Payout', 'Digital', v_digital_required, 'Payroll run payout', p_run_id, p_admin_username);
  end if;

  return query select true, 'Payroll run finalized.'::text;
end;
$$;

grant execute on function public.admin_get_payroll_fund_balances(text, text) to anon;
grant execute on function public.admin_add_payroll_funding_entry(text, text, text, numeric, text) to anon;
grant execute on function public.admin_list_payroll_funding_entries(text, text, int, int) to anon;
grant execute on function public.admin_get_payroll_run_funding_requirement(text, text, uuid) to anon;
grant execute on function public.admin_list_payroll_employees(text, text) to anon;
grant execute on function public.admin_update_payroll_profile(text, text, text, text, numeric, boolean, text) to anon;
grant execute on function public.admin_finalize_payroll_run(text, text, uuid) to anon;
