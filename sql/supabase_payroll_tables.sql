-- Payroll module: a separate admin-only section (Payroll Setup + Payroll Runs) that pays
-- existing StaffUsers rows a fixed salary on either a Semi-Monthly or Weekly cycle. No
-- timesheet/clock-in concept exists in this app - "manual entry" here means the payroll officer
-- can override a run's computed base pay per employee and attach free-form addition/deduction
-- line items (bonus, cash advance, allowance, absence deduction, etc.). No statutory tax tables
-- (SSS/PhilHealth/Pag-IBIG/withholding) - just gross pay plus/minus named line items = net pay.
--
-- Same trust model as every other admin_* RPC in this app (see supabase_staff_users_table.sql) -
-- there is no real session/JWT, so every call re-verifies p_admin_username/p_admin_password via
-- is_admin_authorized() (Super User only, same tier as User Setup). RLS stays enabled with no
-- policies on every table below; the only way in is through these SECURITY DEFINER functions.
--
-- Run this in the Supabase SQL Editor.

-- ---------------------------------------------------------------------------
-- 1. Payroll fields on StaffUsers ("Employees are the one on the usersetup").
-- "PayCycle" is null for staff not enrolled in payroll. "MonthlySalary" is stored as a
-- monthly-equivalent figure regardless of PayCycle - each payroll run derives that employee's
-- base pay for the period from it (SemiMonthly = MonthlySalary / 2, Weekly = MonthlySalary * 12 /
-- 52). These two columns are only ever written by admin_update_payroll_profile below -
-- admin_update_staff_user (User Setup) does not touch them, so editing a login there can't
-- accidentally wipe payroll data.
alter table public."StaffUsers"
    add column if not exists "PayCycle" varchar(20);
alter table public."StaffUsers"
    add column if not exists "MonthlySalary" numeric(18, 2) not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'CK_StaffUsers_PayCycle'
  ) then
    alter table public."StaffUsers"
      add constraint "CK_StaffUsers_PayCycle" check ("PayCycle" is null or "PayCycle" in ('SemiMonthly', 'Weekly'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Payroll runs, lines (one per employee per run), and line items (additions/deductions).

create table if not exists public."PayrollRuns" (
    "RunID" uuid primary key default gen_random_uuid(),
    "PayCycle" varchar(20) not null check ("PayCycle" in ('SemiMonthly', 'Weekly')),
    "PeriodStart" date not null,
    "PeriodEnd" date not null,
    "PayDate" date,
    "Status" varchar(20) not null default 'Draft' check ("Status" in ('Draft', 'Finalized')),
    "CreatedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default timezone('utc', now()),
    "FinalizedBy" varchar(100),
    "FinalizedAtUtc" timestamptz
);

alter table public."PayrollRuns" enable row level security;
revoke all on public."PayrollRuns" from anon, authenticated;

create table if not exists public."PayrollRunLines" (
    "LineID" uuid primary key default gen_random_uuid(),
    "RunID" uuid not null references public."PayrollRuns"("RunID") on delete cascade,
    "Username" varchar(100) not null references public."StaffUsers"("Username"),
    "DisplayName" varchar(200),
    "BasePay" numeric(18, 2) not null default 0,
    "AdditionsTotal" numeric(18, 2) not null default 0,
    "DeductionsTotal" numeric(18, 2) not null default 0,
    "NetPay" numeric(18, 2) not null default 0,
    "Notes" varchar(1000),
    constraint "UQ_PayrollRunLines_Run_Username" unique ("RunID", "Username")
);

alter table public."PayrollRunLines" enable row level security;
revoke all on public."PayrollRunLines" from anon, authenticated;

create index if not exists "IX_PayrollRunLines_RunID" on public."PayrollRunLines" ("RunID");

create table if not exists public."PayrollRunLineItems" (
    "ItemID" uuid primary key default gen_random_uuid(),
    "LineID" uuid not null references public."PayrollRunLines"("LineID") on delete cascade,
    "ItemType" varchar(20) not null check ("ItemType" in ('Addition', 'Deduction')),
    "Label" varchar(200) not null,
    "Amount" numeric(18, 2) not null,
    "CreatedAtUtc" timestamptz not null default timezone('utc', now())
);

alter table public."PayrollRunLineItems" enable row level security;
revoke all on public."PayrollRunLineItems" from anon, authenticated;

create index if not exists "IX_PayrollRunLineItems_LineID" on public."PayrollRunLineItems" ("LineID");

comment on table public."PayrollRuns" is 'One row per payroll run (a Semi-Monthly or Weekly pay period for one or more employees).';
comment on table public."PayrollRunLines" is 'One row per employee within a payroll run - computed/overridden base pay plus totals rolled up from PayrollRunLineItems.';
comment on table public."PayrollRunLineItems" is 'Free-form addition/deduction line items attached to one PayrollRunLines row (bonus, cash advance, allowance, absence deduction, etc).';

-- ---------------------------------------------------------------------------
-- 3. RPCs. All Super-User only (is_admin_authorized, defined in supabase_staff_users_table.sql),
-- same tier as User Setup - Payroll is not exposed to regular staff.

drop function if exists public.admin_list_payroll_employees(text, text);

create or replace function public.admin_list_payroll_employees(p_admin_username text, p_admin_password text)
returns table(
  username text,
  display_name text,
  is_active boolean,
  pay_cycle text,
  monthly_salary numeric
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
    select "Username"::text, "DisplayName"::text, "IsActive", "PayCycle"::text, "MonthlySalary"
    from public."StaffUsers"
    order by "DisplayName", "Username";
end;
$$;

drop function if exists public.admin_update_payroll_profile(text, text, text, text, numeric);

create or replace function public.admin_update_payroll_profile(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_pay_cycle text,
  p_monthly_salary numeric
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_pay_cycle is not null and p_pay_cycle not in ('SemiMonthly', 'Weekly') then
    return query select false, 'Pay cycle must be Semi-Monthly or Weekly.'::text;
    return;
  end if;

  if not exists (select 1 from public."StaffUsers" where "Username" = p_username) then
    return query select false, 'That staff login no longer exists.'::text;
    return;
  end if;

  update public."StaffUsers"
    set "PayCycle" = p_pay_cycle,
        "MonthlySalary" = coalesce(p_monthly_salary, 0)
    where "Username" = p_username;

  return query select true, 'Payroll profile updated.'::text;
end;
$$;

-- Recomputes AdditionsTotal/DeductionsTotal/NetPay on a line from its current line items plus its
-- current BasePay. Called after every line-item insert/delete and every base-pay override so the
-- three totals never drift out of sync with the detail rows.
create or replace function public.recompute_payroll_run_line(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public."PayrollRunLines" l
    set "AdditionsTotal" = coalesce((select sum("Amount") from public."PayrollRunLineItems" where "LineID" = p_line_id and "ItemType" = 'Addition'), 0),
        "DeductionsTotal" = coalesce((select sum("Amount") from public."PayrollRunLineItems" where "LineID" = p_line_id and "ItemType" = 'Deduction'), 0)
    where l."LineID" = p_line_id;

  update public."PayrollRunLines"
    set "NetPay" = "BasePay" + "AdditionsTotal" - "DeductionsTotal"
    where "LineID" = p_line_id;
end;
$$;

drop function if exists public.admin_create_payroll_run(text, text, text, date, date, date);

-- Auto-generates one PayrollRunLines row per active employee whose StaffUsers."PayCycle" matches
-- p_pay_cycle, with BasePay derived from MonthlySalary (SemiMonthly = /2, Weekly = *12/52 -
-- annualize then split across 52 weeks). Raises if no matching employees are enrolled, so an
-- empty run can't be created by mistake.
create or replace function public.admin_create_payroll_run(
  p_admin_username text,
  p_admin_password text,
  p_pay_cycle text,
  p_period_start date,
  p_period_end date,
  p_pay_date date
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_run_id uuid;
  v_inserted int;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_pay_cycle is null or p_pay_cycle not in ('SemiMonthly', 'Weekly') then
    raise exception 'Pay cycle must be Semi-Monthly or Weekly.';
  end if;

  if p_period_start is null or p_period_end is null or p_period_end < p_period_start then
    raise exception 'A valid period start/end is required.';
  end if;

  insert into public."PayrollRuns" ("PayCycle", "PeriodStart", "PeriodEnd", "PayDate", "CreatedBy")
  values (p_pay_cycle, p_period_start, p_period_end, p_pay_date, p_admin_username)
  returning "RunID" into v_run_id;

  insert into public."PayrollRunLines" ("RunID", "Username", "DisplayName", "BasePay", "NetPay")
  select
    v_run_id,
    "Username",
    "DisplayName",
    case p_pay_cycle
      when 'SemiMonthly' then round("MonthlySalary" / 2, 2)
      else round("MonthlySalary" * 12 / 52, 2)
    end,
    case p_pay_cycle
      when 'SemiMonthly' then round("MonthlySalary" / 2, 2)
      else round("MonthlySalary" * 12 / 52, 2)
    end
  from public."StaffUsers"
  where "IsActive" is true and "PayCycle" = p_pay_cycle;

  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    delete from public."PayrollRuns" where "RunID" = v_run_id;
    raise exception 'No active employees are enrolled in the % pay cycle.', p_pay_cycle;
  end if;

  return v_run_id;
end;
$$;

drop function if exists public.admin_list_payroll_runs(text, text, int, int);

create or replace function public.admin_list_payroll_runs(p_admin_username text, p_admin_password text, p_page int default 1, p_page_size int default 50)
returns table(
  run_id uuid,
  pay_cycle text,
  period_start date,
  period_end date,
  pay_date date,
  status text,
  employee_count bigint,
  total_net_pay numeric,
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
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select r."RunID", r."PayCycle"::text, r."PeriodStart", r."PeriodEnd", r."PayDate", r."Status"::text,
           count(l."LineID"), coalesce(sum(l."NetPay"), 0), r."CreatedBy"::text, r."CreatedAtUtc",
           count(*) over()
    from public."PayrollRuns" r
    left join public."PayrollRunLines" l on l."RunID" = r."RunID"
    group by r."RunID"
    order by r."PeriodStart" desc, r."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

drop function if exists public.admin_get_payroll_run(text, text, uuid);

create or replace function public.admin_get_payroll_run(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(
  run_id uuid,
  pay_cycle text,
  period_start date,
  period_end date,
  pay_date date,
  status text,
  created_by text,
  created_at_utc timestamptz,
  finalized_by text,
  finalized_at_utc timestamptz
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
    select "RunID", "PayCycle"::text, "PeriodStart", "PeriodEnd", "PayDate", "Status"::text,
           "CreatedBy"::text, "CreatedAtUtc", "FinalizedBy"::text, "FinalizedAtUtc"
    from public."PayrollRuns"
    where "RunID" = p_run_id;
end;
$$;

drop function if exists public.admin_list_payroll_run_lines(text, text, uuid);

create or replace function public.admin_list_payroll_run_lines(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(
  line_id uuid,
  username text,
  display_name text,
  base_pay numeric,
  additions_total numeric,
  deductions_total numeric,
  net_pay numeric,
  notes text
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
    select "LineID", "Username"::text, "DisplayName"::text, "BasePay", "AdditionsTotal", "DeductionsTotal", "NetPay", "Notes"::text
    from public."PayrollRunLines"
    where "RunID" = p_run_id
    order by "DisplayName", "Username";
end;
$$;

drop function if exists public.admin_update_payroll_run_line_base_pay(text, text, uuid, numeric);

create or replace function public.admin_update_payroll_run_line_base_pay(p_admin_username text, p_admin_password text, p_line_id uuid, p_base_pay numeric)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
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

  update public."PayrollRunLines" set "BasePay" = coalesce(p_base_pay, 0) where "LineID" = p_line_id;
  perform public.recompute_payroll_run_line(p_line_id);

  return query select true, 'Base pay updated.'::text;
end;
$$;

drop function if exists public.admin_update_payroll_run_line_notes(text, text, uuid, text);

create or replace function public.admin_update_payroll_run_line_notes(p_admin_username text, p_admin_password text, p_line_id uuid, p_notes text)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  update public."PayrollRunLines" set "Notes" = nullif(trim(p_notes), '') where "LineID" = p_line_id;

  return query select true, 'Notes updated.'::text;
end;
$$;

drop function if exists public.admin_list_payroll_run_line_items(text, text, uuid);

create or replace function public.admin_list_payroll_run_line_items(p_admin_username text, p_admin_password text, p_line_id uuid)
returns table(item_id uuid, item_type text, label text, amount numeric, created_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "ItemID", "ItemType"::text, "Label"::text, "Amount", "CreatedAtUtc"
    from public."PayrollRunLineItems"
    where "LineID" = p_line_id
    order by "ItemType", "CreatedAtUtc";
end;
$$;

drop function if exists public.admin_add_payroll_line_item(text, text, uuid, text, text, numeric);

create or replace function public.admin_add_payroll_line_item(
  p_admin_username text,
  p_admin_password text,
  p_line_id uuid,
  p_item_type text,
  p_label text,
  p_amount numeric
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_item_type not in ('Addition', 'Deduction') then
    return query select false, 'Item type must be Addition or Deduction.'::text;
    return;
  end if;

  if p_label is null or trim(p_label) = '' then
    return query select false, 'A label is required.'::text;
    return;
  end if;

  if p_amount is null or p_amount <= 0 then
    return query select false, 'Amount must be greater than zero.'::text;
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

  insert into public."PayrollRunLineItems" ("LineID", "ItemType", "Label", "Amount")
  values (p_line_id, p_item_type, trim(p_label), p_amount);

  perform public.recompute_payroll_run_line(p_line_id);

  return query select true, 'Line item added.'::text;
end;
$$;

drop function if exists public.admin_delete_payroll_line_item(text, text, uuid);

create or replace function public.admin_delete_payroll_line_item(p_admin_username text, p_admin_password text, p_item_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line_id uuid;
  v_status text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select i."LineID", r."Status" into v_line_id, v_status
  from public."PayrollRunLineItems" i
  join public."PayrollRunLines" l on l."LineID" = i."LineID"
  join public."PayrollRuns" r on r."RunID" = l."RunID"
  where i."ItemID" = p_item_id;

  if v_line_id is null then
    return query select false, 'Line item not found.'::text;
    return;
  end if;
  if v_status = 'Finalized' then
    return query select false, 'This payroll run is already finalized.'::text;
    return;
  end if;

  delete from public."PayrollRunLineItems" where "ItemID" = p_item_id;
  perform public.recompute_payroll_run_line(v_line_id);

  return query select true, 'Line item removed.'::text;
end;
$$;

drop function if exists public.admin_finalize_payroll_run(text, text, uuid);

create or replace function public.admin_finalize_payroll_run(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
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
    where "RunID" = p_run_id and "Status" = 'Draft';

  return query select true, 'Payroll run finalized.'::text;
end;
$$;

drop function if exists public.admin_delete_payroll_run(text, text, uuid);

-- Only while Draft - a Finalized run is a closed record. Lines/items cascade via FK.
create or replace function public.admin_delete_payroll_run(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  select "Status" into v_status from public."PayrollRuns" where "RunID" = p_run_id;

  if v_status is null then
    return query select false, 'Payroll run not found.'::text;
    return;
  end if;
  if v_status = 'Finalized' then
    return query select false, 'A finalized payroll run cannot be deleted.'::text;
    return;
  end if;

  delete from public."PayrollRuns" where "RunID" = p_run_id;

  return query select true, 'Payroll run deleted.'::text;
end;
$$;

drop function if exists public.admin_get_payroll_payslip(text, text, uuid);

-- Single round-trip for the print page: the line's own figures, its parent run's period info,
-- and a json_agg of its line items (empty array, never null, when there are none).
create or replace function public.admin_get_payroll_payslip(p_admin_username text, p_admin_password text, p_line_id uuid)
returns table(
  line_id uuid,
  run_id uuid,
  username text,
  display_name text,
  pay_cycle text,
  period_start date,
  period_end date,
  pay_date date,
  status text,
  base_pay numeric,
  additions_total numeric,
  deductions_total numeric,
  net_pay numeric,
  notes text,
  items jsonb
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
    select l."LineID", r."RunID", l."Username"::text, l."DisplayName"::text, r."PayCycle"::text,
           r."PeriodStart", r."PeriodEnd", r."PayDate", r."Status"::text,
           l."BasePay", l."AdditionsTotal", l."DeductionsTotal", l."NetPay", l."Notes"::text,
           coalesce(
             (select jsonb_agg(jsonb_build_object('item_type', i."ItemType", 'label', i."Label", 'amount', i."Amount") order by i."ItemType", i."CreatedAtUtc")
              from public."PayrollRunLineItems" i where i."LineID" = l."LineID"),
             '[]'::jsonb
           )
    from public."PayrollRunLines" l
    join public."PayrollRuns" r on r."RunID" = l."RunID"
    where l."LineID" = p_line_id;
end;
$$;

grant execute on function public.admin_list_payroll_employees(text, text) to anon;
grant execute on function public.admin_update_payroll_profile(text, text, text, text, numeric) to anon;
grant execute on function public.admin_create_payroll_run(text, text, text, date, date, date) to anon;
grant execute on function public.admin_list_payroll_runs(text, text, int, int) to anon;
grant execute on function public.admin_get_payroll_run(text, text, uuid) to anon;
grant execute on function public.admin_list_payroll_run_lines(text, text, uuid) to anon;
grant execute on function public.admin_update_payroll_run_line_base_pay(text, text, uuid, numeric) to anon;
grant execute on function public.admin_update_payroll_run_line_notes(text, text, uuid, text) to anon;
grant execute on function public.admin_list_payroll_run_line_items(text, text, uuid) to anon;
grant execute on function public.admin_add_payroll_line_item(text, text, uuid, text, text, numeric) to anon;
grant execute on function public.admin_delete_payroll_line_item(text, text, uuid) to anon;
grant execute on function public.admin_finalize_payroll_run(text, text, uuid) to anon;
grant execute on function public.admin_delete_payroll_run(text, text, uuid) to anon;
grant execute on function public.admin_get_payroll_payslip(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- 4. Semi-Monthly cutoff settings - a singleton row (Id = 1, same pattern as CompanyInfo) so
-- "New Payroll Run" can auto-fill Period Start/End/Pay Date instead of the officer retyping the
-- same two fixed cutoffs every run. StartDay/EndDay are day-of-month numbers; StartDay > EndDay
-- means the period starts in the month BEFORE the one being run (e.g. 26 -> 10 spans two
-- months). Each cutoff's pay date is either a fixed day-of-month (PayDay) or the last calendar
-- day of the run's target month (PayDayIsLastDayOfMonth), never both.
create table if not exists public."PayrollCutoffSettings" (
    "Id" int primary key default 1,
    "CutoffAStartDay" int not null,
    "CutoffAEndDay" int not null,
    "CutoffAPayDay" int,
    "CutoffAPayDayIsLastDayOfMonth" boolean not null default false,
    "CutoffBStartDay" int not null,
    "CutoffBEndDay" int not null,
    "CutoffBPayDay" int,
    "CutoffBPayDayIsLastDayOfMonth" boolean not null default false,
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default timezone('utc', now()),
    constraint "CK_PayrollCutoffSettings_SingleRow" check ("Id" = 1)
);

alter table public."PayrollCutoffSettings" enable row level security;
revoke all on public."PayrollCutoffSettings" from anon, authenticated;

-- Seeded with the actual cutoffs in use: 26th-10th paid the 15th, 11th-25th paid the last day of
-- the month.
insert into public."PayrollCutoffSettings" ("Id", "CutoffAStartDay", "CutoffAEndDay", "CutoffAPayDay", "CutoffAPayDayIsLastDayOfMonth", "CutoffBStartDay", "CutoffBEndDay", "CutoffBPayDay", "CutoffBPayDayIsLastDayOfMonth")
select 1, 26, 10, 15, false, 11, 25, null, true
where not exists (select 1 from public."PayrollCutoffSettings" where "Id" = 1);

comment on table public."PayrollCutoffSettings" is 'Singleton row of the two fixed Semi-Monthly cutoff day-ranges and pay-date rules, edited from Payroll Setup.';

drop function if exists public.admin_get_payroll_cutoff_settings(text, text);

create or replace function public.admin_get_payroll_cutoff_settings(p_admin_username text, p_admin_password text)
returns table(
  cutoff_a_start_day int,
  cutoff_a_end_day int,
  cutoff_a_pay_day int,
  cutoff_a_pay_day_is_last_day_of_month boolean,
  cutoff_b_start_day int,
  cutoff_b_end_day int,
  cutoff_b_pay_day int,
  cutoff_b_pay_day_is_last_day_of_month boolean
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
    select "CutoffAStartDay", "CutoffAEndDay", "CutoffAPayDay", "CutoffAPayDayIsLastDayOfMonth",
           "CutoffBStartDay", "CutoffBEndDay", "CutoffBPayDay", "CutoffBPayDayIsLastDayOfMonth"
    from public."PayrollCutoffSettings"
    where "Id" = 1;
end;
$$;

drop function if exists public.admin_upsert_payroll_cutoff_settings(text, text, int, int, int, boolean, int, int, int, boolean);

create or replace function public.admin_upsert_payroll_cutoff_settings(
  p_admin_username text,
  p_admin_password text,
  p_cutoff_a_start_day int,
  p_cutoff_a_end_day int,
  p_cutoff_a_pay_day int,
  p_cutoff_a_pay_day_is_last_day_of_month boolean,
  p_cutoff_b_start_day int,
  p_cutoff_b_end_day int,
  p_cutoff_b_pay_day int,
  p_cutoff_b_pay_day_is_last_day_of_month boolean
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_cutoff_a_start_day not between 1 and 31 or p_cutoff_a_end_day not between 1 and 31
     or p_cutoff_b_start_day not between 1 and 31 or p_cutoff_b_end_day not between 1 and 31 then
    return query select false, 'Cutoff days must be between 1 and 31.'::text;
    return;
  end if;

  if not p_cutoff_a_pay_day_is_last_day_of_month and (p_cutoff_a_pay_day is null or p_cutoff_a_pay_day not between 1 and 31) then
    return query select false, 'Cutoff A needs a pay day (or use last day of month).'::text;
    return;
  end if;
  if not p_cutoff_b_pay_day_is_last_day_of_month and (p_cutoff_b_pay_day is null or p_cutoff_b_pay_day not between 1 and 31) then
    return query select false, 'Cutoff B needs a pay day (or use last day of month).'::text;
    return;
  end if;

  insert into public."PayrollCutoffSettings" (
    "Id", "CutoffAStartDay", "CutoffAEndDay", "CutoffAPayDay", "CutoffAPayDayIsLastDayOfMonth",
    "CutoffBStartDay", "CutoffBEndDay", "CutoffBPayDay", "CutoffBPayDayIsLastDayOfMonth",
    "UpdatedBy", "UpdatedAtUtc"
  )
  values (
    1, p_cutoff_a_start_day, p_cutoff_a_end_day, p_cutoff_a_pay_day, coalesce(p_cutoff_a_pay_day_is_last_day_of_month, false),
    p_cutoff_b_start_day, p_cutoff_b_end_day, p_cutoff_b_pay_day, coalesce(p_cutoff_b_pay_day_is_last_day_of_month, false),
    p_admin_username, timezone('utc', now())
  )
  on conflict ("Id") do update
    set "CutoffAStartDay" = excluded."CutoffAStartDay",
        "CutoffAEndDay" = excluded."CutoffAEndDay",
        "CutoffAPayDay" = excluded."CutoffAPayDay",
        "CutoffAPayDayIsLastDayOfMonth" = excluded."CutoffAPayDayIsLastDayOfMonth",
        "CutoffBStartDay" = excluded."CutoffBStartDay",
        "CutoffBEndDay" = excluded."CutoffBEndDay",
        "CutoffBPayDay" = excluded."CutoffBPayDay",
        "CutoffBPayDayIsLastDayOfMonth" = excluded."CutoffBPayDayIsLastDayOfMonth",
        "UpdatedBy" = excluded."UpdatedBy",
        "UpdatedAtUtc" = excluded."UpdatedAtUtc";

  return query select true, 'Cutoff settings updated.'::text;
end;
$$;

grant execute on function public.admin_get_payroll_cutoff_settings(text, text) to anon;
grant execute on function public.admin_upsert_payroll_cutoff_settings(text, text, int, int, int, boolean, int, int, int, boolean) to anon;
