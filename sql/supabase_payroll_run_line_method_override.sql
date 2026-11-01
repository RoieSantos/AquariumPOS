-- Payroll Run: change an employee's pay method for one run only - per "in the payrun is it possible
-- to change the pay method of that payrun sometimes they are paying digital instead of cash".
--
-- New PayrollRunLines."PaymentMethod". While NULL the line follows the employee's StaffUsers."PaymentMethod"
-- (unset = Cash, same rule as before); the Lines grid's dropdown sets it for that run without touching
-- the employee's default. Finalize stamps every line's method, so a later change to the employee's
-- default can't alter how a finalized run displays.
--
-- Run AFTER supabase_payroll_ledger_funding_merge.sql and supabase_payroll_run_lines_payment_method.sql
-- (this replaces their admin_finalize_payroll_run / admin_list_payroll_run_lines). Safe to re-run.
-- Needs js/payrollRun.js ?v=paymethod2.

alter table public."PayrollRunLines"
    add column if not exists "PaymentMethod" varchar(20);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'CK_PayrollRunLines_PaymentMethod') then
    alter table public."PayrollRunLines"
      add constraint "CK_PayrollRunLines_PaymentMethod"
      check ("PaymentMethod" is null or "PaymentMethod" in ('Cash', 'Digital'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- admin_set_payroll_run_line_method: Draft runs only, same lock as the other line edit RPCs.

create or replace function public.admin_set_payroll_run_line_method(p_admin_username text, p_admin_password text, p_line_id uuid, p_method text)
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

  if p_method is null or p_method not in ('Cash', 'Digital') then
    return query select false, 'Method must be Cash or Digital.'::text;
    return;
  end if;

  select r."Status" into v_status
  from public."PayrollRunLines" l join public."PayrollRuns" r on r."RunID" = l."RunID"
  where l."LineID" = p_line_id;

  if v_status is null then
    return query select false, 'Payroll line not found.'::text;
    return;
  end if;
  if v_status = 'Finalized' then
    return query select false, 'This payroll run is already finalized.'::text;
    return;
  end if;

  update public."PayrollRunLines" set "PaymentMethod" = p_method where "LineID" = p_line_id;

  return query select true, 'Pay method updated.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_run_lines: same columns - payment_method now prefers the line's own method.

create or replace function public.admin_list_payroll_run_lines(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(
  line_id uuid,
  username text,
  display_name text,
  pay_type text,
  base_pay numeric,
  additions_total numeric,
  deductions_total numeric,
  net_pay numeric,
  notes text,
  days_worked numeric,
  daily_rate numeric,
  daily_rate_breakdown jsonb,
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
    select l."LineID", l."Username"::text, l."DisplayName"::text, coalesce(su."PayType", 'Salary')::text,
           l."BasePay", l."AdditionsTotal", l."DeductionsTotal", l."NetPay", l."Notes"::text,
           l."DaysWorked", l."DailyRate", l."DailyRateBreakdown",
           coalesce(l."PaymentMethod", su."PaymentMethod", 'Cash')::text
    from public."PayrollRunLines" l
    left join public."StaffUsers" su on su."Username" = l."Username"
    where l."RunID" = p_run_id
    order by l."DisplayName", l."Username";
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_get_payroll_run_funding_requirement: same signature - required totals follow the line's method.

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
      coalesce(sum(l."NetPay") filter (where coalesce(l."PaymentMethod", su."PaymentMethod", 'Cash') = 'Cash'), 0),
      coalesce(sum(l."NetPay") filter (where coalesce(l."PaymentMethod", su."PaymentMethod", 'Cash') = 'Digital'), 0),
      public.payroll_fund_balance('Cash'),
      public.payroll_fund_balance('Digital')
    from public."PayrollRunLines" l
    join public."StaffUsers" su on su."Username" = l."Username"
    where l."RunID" = p_run_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_finalize_payroll_run: same signature - required totals and Payroll Payout rows follow the
-- line's method, and each line's method is stamped at Finalize.

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

  select coalesce(sum(l."NetPay") filter (where coalesce(l."PaymentMethod", su."PaymentMethod", 'Cash') = 'Cash'), 0),
         coalesce(sum(l."NetPay") filter (where coalesce(l."PaymentMethod", su."PaymentMethod", 'Cash') = 'Digital'), 0)
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

  update public."PayrollRunLines" l
    set "PaymentMethod" = coalesce(l."PaymentMethod", su."PaymentMethod", 'Cash')
    from public."StaffUsers" su
    where su."Username" = l."Username" and l."RunID" = p_run_id;

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
    insert into public."PayrollLedgerEntries"
      ("RunID", "PayCycle", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "PostedBy")
    values (p_run_id, v_pay_cycle, v_period_start, v_period_end, v_pay_date, 'Payroll', 'Payroll Payout', v_cash_required, 'Cash', p_admin_username);
  end if;

  if v_digital_required > 0 then
    insert into public."PayrollLedgerEntries"
      ("RunID", "PayCycle", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "PostedBy")
    values (p_run_id, v_pay_cycle, v_period_start, v_period_end, v_pay_date, 'Payroll', 'Payroll Payout', v_digital_required, 'Digital', p_admin_username);
  end if;

  return query select true, 'Payroll run finalized.'::text;
end;
$$;

grant execute on function public.admin_set_payroll_run_line_method(text, text, uuid, text) to anon;
grant execute on function public.admin_list_payroll_run_lines(text, text, uuid) to anon;
grant execute on function public.admin_get_payroll_run_funding_requirement(text, text, uuid) to anon;
grant execute on function public.admin_finalize_payroll_run(text, text, uuid) to anon;

-- Check: should return true for all three.
select
  exists (select 1 from information_schema.columns where table_name = 'PayrollRunLines' and column_name = 'PaymentMethod') as line_column_added,
  (pg_get_functiondef('public.admin_finalize_payroll_run(text, text, uuid)'::regprocedure) like '%l."PaymentMethod", su."PaymentMethod"%') as finalize_uses_line_method,
  (to_regprocedure('public.admin_set_payroll_run_line_method(text, text, uuid, text)') is not null) as set_method_rpc_exists;
