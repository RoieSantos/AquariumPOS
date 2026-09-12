-- Hard-blocks logging a Cash Advance that would push Cash on Hand / Digital on Hand below zero,
-- same "hard block, not just a warning" treatment admin_finalize_payroll_run already gives a
-- Finalize that can't be covered. Per: "if cash on hand or digital will be less than 0 prompt an
-- error message saying this will not go through since the fund is less."
--
-- admin_add_cash_advance (Payroll Setup's log form) only ever adds one new advance, so it's a
-- single balance check. admin_upsert_cash_advances_bulk (Timesheets weekly grid) can touch many
-- employees' advances in one Save All click, so it runs a full validation pass first - simulating
-- every entry's effect on both running balances (an update changes the delta between the old and
-- new amount, not the full new amount; a delete/clear only ever frees up funds) - and only if every
-- entry passes does it actually write anything. That keeps the whole batch atomic: either all of it
-- goes through, or none of it does, never a partial save.
--
-- Run this AFTER supabase_payroll_ledger_funding_merge.sql.

-- ---------------------------------------------------------------------------
-- admin_add_cash_advance: same signature - now checks payroll_fund_balance(method) first.

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
  v_balance numeric;
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

  v_balance := public.payroll_fund_balance(v_method);
  if p_amount > v_balance then
    return query select false,
      ('Insufficient ' || v_method || ' on Hand: this advance needs ' || to_char(p_amount, 'FM999,999,990.00') ||
       ', only ' || to_char(v_balance, 'FM999,999,990.00') || ' on hand. This will not go through - log a ' ||
       v_method || ' funding entry first.')::text;
    return;
  end if;

  insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Notes", "Method", "CreatedBy")
  values (p_username, p_advance_date, p_amount, nullif(trim(p_notes), ''), v_method, p_admin_username)
  returning "AdvanceID" into v_advance_id;

  insert into public."PayrollLedgerEntries"
    ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "SourceAdvanceID", "PostedBy")
  values (p_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', p_amount, v_method, v_advance_id, p_admin_username);

  return query select true, 'Cash advance logged.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_upsert_cash_advances_bulk: same signature - a first validation pass simulates every
-- entry's effect on the running Cash/Digital balance before a second pass writes anything.

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
  v_old_amount numeric;
  v_old_method text;
  v_sim_cash numeric;
  v_sim_digital numeric;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_advance_date is null or p_week_start is null or p_week_end is null then
    return query select false, 'A valid advance date and week range are required.'::text;
    return;
  end if;

  -- Pass 1: validate. Simulate the combined effect of every entry in this batch on the running
  -- Cash/Digital balance, then check once at the end - not after each entry. Blaming whichever
  -- employee's row happened to be processed at the moment a running total crossed zero would be
  -- arbitrary (it depends on iteration order, not on who actually "caused" the shortfall - it could
  -- even land on a row with nothing entered), so this only ever reports the method and the total
  -- shortfall, never an employee name.
  v_sim_cash := public.payroll_fund_balance('Cash');
  v_sim_digital := public.payroll_fund_balance('Digital');

  for v_entry in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb))
  loop
    v_username := v_entry->>'username';
    v_amount := nullif(v_entry->>'amount', '')::numeric;
    v_method := v_entry->>'method';
    if coalesce(v_method, '') not in ('Cash', 'Digital') then
      v_method := 'Cash';
    end if;

    if not exists (select 1 from public."StaffUsers" where "Username" = v_username) then
      continue;
    end if;

    select "AdvanceID", "Amount", "Method" into v_existing_id, v_old_amount, v_old_method
      from public."PayrollCashAdvances"
      where "Username" = v_username and "Status" = 'Outstanding'
        and "AdvanceDate" between p_week_start and p_week_end
      order by "AdvanceDate"
      limit 1;

    if coalesce(v_amount, 0) > 0 then
      if v_existing_id is not null then
        -- Editing an existing advance: free up what it currently holds, then re-reserve the new
        -- amount (possibly on a different method).
        if v_old_method = 'Cash' then v_sim_cash := v_sim_cash + v_old_amount; else v_sim_digital := v_sim_digital + v_old_amount; end if;
      end if;
      if v_method = 'Cash' then v_sim_cash := v_sim_cash - v_amount; else v_sim_digital := v_sim_digital - v_amount; end if;
    else
      -- Cleared back to blank/0: deletes the existing advance, which only ever frees up funds.
      if v_existing_id is not null then
        if v_old_method = 'Cash' then v_sim_cash := v_sim_cash + v_old_amount; else v_sim_digital := v_sim_digital + v_old_amount; end if;
      end if;
    end if;
  end loop;

  if v_sim_cash < 0 then
    return query select false,
      ('Insufficient Cash on Hand to save these Cash Advances - short by ' || to_char(-v_sim_cash, 'FM999,999,990.00') ||
       '. This will not go through - log a Cash funding entry first.')::text;
    return;
  end if;
  if v_sim_digital < 0 then
    return query select false,
      ('Insufficient Digital on Hand to save these Cash Advances - short by ' || to_char(-v_sim_digital, 'FM999,999,990.00') ||
       '. This will not go through - log a Digital funding entry first.')::text;
    return;
  end if;

  -- Pass 2: every entry passed validation - now actually write them.
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

grant execute on function public.admin_add_cash_advance(text, text, text, date, numeric, text, text) to anon;
grant execute on function public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb) to anon;
