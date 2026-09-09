-- Lets a "Payroll Officer" (supabase_staff_users_payroll_officer_field.sql) actually use the
-- Payroll pages once js/auth.js widens the client-side gate to `isSuperUser || isPayrollOfficer`.
-- That client-side gate alone is NOT enough: every Payroll RPC below re-checks authorization
-- server-side via is_admin_authorized(), which only ever allows "SuperUser" = true - a non-super
-- Payroll Officer would open the page and then have every single RPC call fail with "Not
-- authorized." This file adds a parallel is_payroll_authorized() (SuperUser OR PayrollOfficer,
-- still active + password-checked, same as is_admin_authorized) and swaps every Payroll RPC's
-- authorization check over to it. Nothing else about these functions changes - same signatures,
-- same bodies, same grants (already in place from supabase_payroll_tables.sql/
-- supabase_payroll_ledger.sql/supabase_payroll_profile_active_toggle.sql), so `create or replace`
-- is enough here - no drops needed.
--
-- Everywhere else in the portal (User Setup, Warehouse, Item Setup, General Setup, etc.) still
-- requires true SuperUser - only the Payroll RPCs listed here accept PayrollOfficer as an
-- alternative.
--
-- Run this AFTER supabase_staff_users_payroll_officer_field.sql, supabase_payroll_tables.sql,
-- supabase_payroll_ledger.sql, and supabase_payroll_profile_active_toggle.sql.

drop function if exists public.is_payroll_authorized(text, text);

create or replace function public.is_payroll_authorized(p_username text, p_password text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_password_hash text;
  v_is_active boolean;
  v_super_user boolean;
  v_payroll_officer boolean;
begin
  select "PasswordHash", "IsActive", "SuperUser", "PayrollOfficer"
    into v_password_hash, v_is_active, v_super_user, v_payroll_officer
    from public."StaffUsers"
    where "Username" = p_username;

  if not found or not v_is_active then
    return false;
  end if;

  if not (coalesce(v_super_user, false) or coalesce(v_payroll_officer, false)) then
    return false;
  end if;

  return v_password_hash = crypt(p_password, v_password_hash);
end;
$$;

-- Same as is_admin_authorized - intentionally NOT granted to anon, only callable from inside the
-- other security definer functions below.

-- ---------------------------------------------------------------------------
-- admin_list_payroll_employees

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "Username"::text, "DisplayName"::text, "IsActive", "PayCycle"::text, "MonthlySalary"
    from public."StaffUsers"
    order by "DisplayName", "Username";
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_update_payroll_profile (current signature: supabase_payroll_profile_active_toggle.sql)

create or replace function public.admin_update_payroll_profile(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_pay_cycle text,
  p_monthly_salary numeric,
  p_is_active boolean default true
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

  if not exists (select 1 from public."StaffUsers" where "Username" = p_username) then
    return query select false, 'That staff login no longer exists.'::text;
    return;
  end if;

  update public."StaffUsers"
    set "PayCycle" = p_pay_cycle,
        "MonthlySalary" = coalesce(p_monthly_salary, 0),
        "IsActive" = coalesce(p_is_active, true)
    where "Username" = p_username;

  return query select true, 'Payroll profile updated.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_create_payroll_run

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
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

-- ---------------------------------------------------------------------------
-- admin_list_payroll_runs

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
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

-- ---------------------------------------------------------------------------
-- admin_get_payroll_run

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "RunID", "PayCycle"::text, "PeriodStart", "PeriodEnd", "PayDate", "Status"::text,
           "CreatedBy"::text, "CreatedAtUtc", "FinalizedBy"::text, "FinalizedAtUtc"
    from public."PayrollRuns"
    where "RunID" = p_run_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_run_lines

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "LineID", "Username"::text, "DisplayName"::text, "BasePay", "AdditionsTotal", "DeductionsTotal", "NetPay", "Notes"::text
    from public."PayrollRunLines"
    where "RunID" = p_run_id
    order by "DisplayName", "Username";
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_update_payroll_run_line_base_pay

create or replace function public.admin_update_payroll_run_line_base_pay(p_admin_username text, p_admin_password text, p_line_id uuid, p_base_pay numeric)
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

-- ---------------------------------------------------------------------------
-- admin_update_payroll_run_line_notes

create or replace function public.admin_update_payroll_run_line_notes(p_admin_username text, p_admin_password text, p_line_id uuid, p_notes text)
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

  update public."PayrollRunLines" set "Notes" = nullif(trim(p_notes), '') where "LineID" = p_line_id;

  return query select true, 'Notes updated.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_run_line_items

create or replace function public.admin_list_payroll_run_line_items(p_admin_username text, p_admin_password text, p_line_id uuid)
returns table(item_id uuid, item_type text, label text, amount numeric, created_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "ItemID", "ItemType"::text, "Label"::text, "Amount", "CreatedAtUtc"
    from public."PayrollRunLineItems"
    where "LineID" = p_line_id
    order by "ItemType", "CreatedAtUtc";
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_add_payroll_line_item

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
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

-- ---------------------------------------------------------------------------
-- admin_delete_payroll_line_item

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
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

-- ---------------------------------------------------------------------------
-- admin_finalize_payroll_run (current body: supabase_payroll_ledger.sql - posts ledger entries)

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
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

-- ---------------------------------------------------------------------------
-- admin_delete_payroll_run

create or replace function public.admin_delete_payroll_run(p_admin_username text, p_admin_password text, p_run_id uuid)
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

-- ---------------------------------------------------------------------------
-- admin_get_payroll_payslip

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
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

-- ---------------------------------------------------------------------------
-- admin_get_payroll_cutoff_settings

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select "CutoffAStartDay", "CutoffAEndDay", "CutoffAPayDay", "CutoffAPayDayIsLastDayOfMonth",
           "CutoffBStartDay", "CutoffBEndDay", "CutoffBPayDay", "CutoffBPayDayIsLastDayOfMonth"
    from public."PayrollCutoffSettings"
    where "Id" = 1;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_upsert_payroll_cutoff_settings

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
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

-- ---------------------------------------------------------------------------
-- admin_list_payroll_ledger_entries

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
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
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
