-- Retires PayrollFundingLedger as a separate table - per "i think funding should be writing on
-- the ledger too right? no need the funding ledger. it should be add type 'funding' and the other
-- type 'Payroll'." Everything that used to live in PayrollFundingLedger (Funding receipts, and the
-- aggregate Cash/Digital payout posted at Finalize, previously EntryType='Payout') now posts
-- straight into PayrollLedgerEntries as EntryType='Funding' / 'Payroll' respectively, alongside the
-- existing BasePay/Addition/Deduction/NetPay/CashAdvance rows. Cash on Hand / Digital on Hand is
-- now just: sum(Funding) - sum(Payroll) - sum(CashAdvance), all from one table, filtered by Method
-- (only these three EntryTypes ever carry a Method - a per-employee BasePay/Addition/Deduction/
-- NetPay row never does).
--
-- PayrollFundingLedger itself is NOT dropped - its historical rows are backfilled into
-- PayrollLedgerEntries below (guarded so this is safe to run more than once) and the table is then
-- simply unused going forward. Left in place rather than dropped so no history is destroyed if
-- something here needs to be double-checked later.
--
-- Run this AFTER supabase_payroll_ledger_pagination_filters.sql and
-- supabase_payroll_cash_advance_funding_ledger.sql.

-- ---------------------------------------------------------------------------
-- Schema: Username was required (every prior EntryType is tied to one employee) - Funding/Payroll
-- rows are company-level, not employee-level, so it's relaxed the same way RunID/LineID/PayCycle/
-- PeriodStart/PeriodEnd already were for CashAdvance. Notes is new - PayrollFundingLedger had a
-- genuine free-text Notes field distinct from its category Label; PayrollLedgerEntries only had
-- Label before.

alter table public."PayrollLedgerEntries" alter column "Username" drop not null;

alter table public."PayrollLedgerEntries"
    add column if not exists "Notes" varchar(500);

do $$
begin
  if exists (select 1 from pg_constraint where conname = 'CK_PayrollLedgerEntries_EntryType') then
    alter table public."PayrollLedgerEntries" drop constraint "CK_PayrollLedgerEntries_EntryType";
  end if;
  alter table public."PayrollLedgerEntries"
    add constraint "CK_PayrollLedgerEntries_EntryType"
    check ("EntryType" in ('BasePay', 'Addition', 'Deduction', 'NetPay', 'CashAdvance', 'Funding', 'Payroll'));
end $$;

-- ---------------------------------------------------------------------------
-- One-time backfill of PayrollFundingLedger's history, so existing Cash/Digital balances don't
-- suddenly change once payroll_fund_balance() stops reading that table. Guarded to only run if no
-- Funding/Payroll rows exist yet in PayrollLedgerEntries (safe to re-run this whole script).

do $$
begin
  if not exists (select 1 from public."PayrollLedgerEntries" where "EntryType" in ('Funding', 'Payroll')) then
    insert into public."PayrollLedgerEntries"
      ("RunID", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Notes", "Amount", "Method", "PostedBy", "PostedAtUtc")
    select
      fl."RunID",
      fl."PostedAtUtc"::date,
      fl."PostedAtUtc"::date,
      fl."PostedAtUtc"::date,
      case when fl."EntryType" = 'Funding' then 'Funding' else 'Payroll' end,
      case when fl."EntryType" = 'Funding' then 'Funding' else 'Payroll Payout' end,
      fl."Notes",
      fl."Amount",
      fl."Method",
      fl."PostedBy",
      fl."PostedAtUtc"
    from public."PayrollFundingLedger" fl;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- payroll_fund_balance: now reads PayrollLedgerEntries.

create or replace function public.payroll_fund_balance(p_method text)
returns numeric
language sql
security definer
set search_path = public, extensions
as $$
  select coalesce(sum(case when "EntryType" = 'Funding' then "Amount" else -"Amount" end), 0)
  from public."PayrollLedgerEntries"
  where "Method" = p_method and "EntryType" in ('Funding', 'Payroll', 'CashAdvance');
$$;

-- ---------------------------------------------------------------------------
-- admin_add_payroll_funding_entry: same signature - now posts EntryType='Funding' straight to
-- PayrollLedgerEntries instead of PayrollFundingLedger.

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

  insert into public."PayrollLedgerEntries"
    ("PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Notes", "Amount", "Method", "PostedBy")
  values (timezone('utc', now())::date, timezone('utc', now())::date, timezone('utc', now())::date,
          'Funding', 'Funding', nullif(trim(p_notes), ''), p_amount, p_method, p_admin_username);

  return query select true, 'Funding entry logged.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_finalize_payroll_run: same signature and same hard-block logic - only the final two
-- inserts change, from PayrollFundingLedger EntryType='Payout' to PayrollLedgerEntries
-- EntryType='Payroll'.

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

-- ---------------------------------------------------------------------------
-- admin_add_cash_advance / admin_delete_cash_advance / admin_upsert_cash_advances_bulk: same
-- signatures - PayrollFundingLedger inserts/updates/deletes removed (CashAdvance rows in
-- PayrollLedgerEntries already carry a Method and are already counted by payroll_fund_balance, so
-- there's nothing left for those statements to do).

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

  return query select true, 'Cash advance logged.'::text;
end;
$$;

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
-- admin_list_payroll_funding_entries: retired - Payroll Setup's Funding Journal now calls
-- admin_list_payroll_ledger_entries (below) filtered by Method instead.

drop function if exists public.admin_list_payroll_funding_entries(text, text, int, int, text);

-- ---------------------------------------------------------------------------
-- admin_list_payroll_ledger_entries: adds p_method (filters to one method) and p_funding_only
-- (filters to rows that carry ANY method, i.e. Funding/Payroll/CashAdvance - the three EntryTypes
-- that affect Cash on Hand/Digital on Hand; a per-employee BasePay/Addition/Deduction/NetPay row
-- never has a Method). Payroll Setup's Funding Journal passes p_funding_only:true always, plus
-- p_method when narrowed to one balance; the general Payroll Ledger report never sets it. Also
-- returns notes.

drop function if exists public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date, text, text, int, int);

create or replace function public.admin_list_payroll_ledger_entries(
  p_admin_username text,
  p_admin_password text,
  p_run_id uuid default null,
  p_username text default null,
  p_period_start date default null,
  p_period_end date default null,
  p_search text default null,
  p_entry_type text default null,
  p_page int default null,
  p_page_size int default 50,
  p_method text default null,
  p_funding_only boolean default false
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
  notes text,
  amount numeric,
  method text,
  source_advance_id uuid,
  posted_by text,
  posted_at_utc timestamptz,
  total_count bigint,
  total_net_pay numeric
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
           "PeriodStart", "PeriodEnd", "PayDate", "EntryType"::text, "Label"::text, "Notes"::text, "Amount", "Method"::text,
           "SourceAdvanceID", "PostedBy"::text, "PostedAtUtc",
           count(*) over (),
           sum(case when "EntryType" = 'NetPay' then "Amount" else 0 end) over ()
    from public."PayrollLedgerEntries"
    where (p_run_id is null or "RunID" = p_run_id)
      and (p_username is null or "Username" = p_username)
      and (p_period_start is null or "PeriodEnd" >= p_period_start)
      and (p_period_end is null or "PeriodStart" <= p_period_end)
      and (p_entry_type is null or "EntryType" = p_entry_type)
      and (p_method is null or "Method" = p_method)
      and (not p_funding_only or "Method" is not null)
      and (
        p_search is null or trim(p_search) = '' or
        "Label" ilike '%' || trim(p_search) || '%' or
        "DisplayName" ilike '%' || trim(p_search) || '%' or
        "Username" ilike '%' || trim(p_search) || '%'
      )
    order by "PostedAtUtc" desc, "DisplayName",
      case "EntryType" when 'CashAdvance' then 0 when 'BasePay' then 1 when 'Addition' then 2 when 'Deduction' then 3 else 4 end
    limit case when p_page is null then null else greatest(coalesce(p_page_size, 50), 1) end
    offset case when p_page is null then 0 else (greatest(p_page, 1) - 1) * greatest(coalesce(p_page_size, 50), 1) end;
end;
$$;

grant execute on function public.admin_get_payroll_fund_balances(text, text) to anon;
grant execute on function public.admin_add_payroll_funding_entry(text, text, text, numeric, text) to anon;
grant execute on function public.admin_get_payroll_run_funding_requirement(text, text, uuid) to anon;
grant execute on function public.admin_finalize_payroll_run(text, text, uuid) to anon;
grant execute on function public.admin_add_cash_advance(text, text, text, date, numeric, text, text) to anon;
grant execute on function public.admin_delete_cash_advance(text, text, uuid) to anon;
grant execute on function public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb) to anon;
grant execute on function public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date, text, text, int, int, text, boolean) to anon;
