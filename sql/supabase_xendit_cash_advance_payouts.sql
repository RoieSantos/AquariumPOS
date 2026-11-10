-- Cash advances through Xendit - per "we are releasing cash advance for the employee every thursday how are we
-- going to implement that?" ... "yes we decide the amount".
--
--   - Timesheets weekly grid: the Cash Advance Method can now be Xendit (only for an employee with a payout
--     account; it starts as Xendit for a "Pay salary via Xendit" employee). Amounts are still typed every week.
--   - A Xendit advance is saved as 'Pending' (new status) - it doesn't use Cash / Digital on Hand, and a payroll
--     run does NOT deduct it yet (admin_create_payroll_run only pulls 'Outstanding').
--   - Timesheets > Send Advances via Xendit (super users) sends the Pending ones; when Xendit confirms the payout
--     (webhook / Refresh Status) the advance turns 'Outstanding' and the next payroll run deducts it as usual.
--     A failed one stays Pending - fix the account and send again, or switch it to Cash.
--   - Approval - per "a payroll officer submit for approval": after Save All the officer clicks Submit for Approval
--     (admin_submit_cash_advances); a super user can only send SUBMITTED advances. Changing a submitted advance's
--     amount or method takes it back out of approval until it's submitted again.
--   - An advance with a live payout sent / paid can't be edited or deleted. Test-mode payouts never change an
--     advance's status (no real money).
--   - Same XenditPayouts table, payout accounts, key, webhook and Idempotency-key protection as salary payouts.
--
-- Run AFTER supabase_xendit_payroll_payouts.sql and supabase_payroll_cash_advance_balance_guard.sql (replaces
-- admin_add_cash_advance, admin_upsert_cash_advances_bulk, admin_delete_cash_advance and _payroll_payout_record).
-- Safe to re-run. Needs js/payrollTimesheets.js ?v=xadvance1, js/payrollSetup.js ?v=xadvance1 and the updated
-- xendit-payroll-payout Edge Function. Ends with ONE result.

-- ---------------------------------------------------------------------------
-- PayrollCashAdvances: 'Pending' status, 'Xendit' method.

do $$
declare
  c record;
begin
  -- The Status check was declared inline (auto-named) - drop whatever check mentions Status.
  for c in
    select conname from pg_constraint
    where conrelid = 'public."PayrollCashAdvances"'::regclass and contype = 'c'
      and pg_get_constraintdef(oid) like '%"Status"%'
  loop
    execute format('alter table public."PayrollCashAdvances" drop constraint %I', c.conname);
  end loop;
end;
$$;

alter table public."PayrollCashAdvances"
  add constraint "CK_PayrollCashAdvances_Status" check ("Status" in ('Pending', 'Outstanding', 'Applied', 'Cancelled'));

alter table public."PayrollCashAdvances" drop constraint if exists "CK_PayrollCashAdvances_Method";
alter table public."PayrollCashAdvances"
  add constraint "CK_PayrollCashAdvances_Method" check ("Method" in ('Cash', 'Digital', 'Xendit'));

-- Submitted for approval (Xendit advances only); the approval itself is the super user's send (XenditPayouts.SentBy).
alter table public."PayrollCashAdvances" add column if not exists "SubmittedBy" text;
alter table public."PayrollCashAdvances" add column if not exists "SubmittedAtUtc" timestamptz;

-- ---------------------------------------------------------------------------
-- XenditPayouts: also holds advance payouts.

alter table public."XenditPayouts" add column if not exists "Kind" text not null default 'Salary';
alter table public."XenditPayouts" add column if not exists "AdvanceID" uuid references public."PayrollCashAdvances" ("AdvanceID") on delete set null;
alter table public."XenditPayouts" alter column "RunID" drop not null;
alter table public."XenditPayouts" alter column "LineID" drop not null;

alter table public."XenditPayouts" drop constraint if exists "CK_XenditPayouts_Kind";
alter table public."XenditPayouts"
  add constraint "CK_XenditPayouts_Kind" check (
    ("Kind" = 'Salary' and "RunID" is not null and "LineID" is not null) or "Kind" = 'Advance');

create unique index if not exists "UX_XenditPayouts_ActiveAdvance" on public."XenditPayouts" ("AdvanceID", "IsTest")
  where "AdvanceID" is not null and "Status" not in ('FAILED', 'CANCELLED', 'REVERSED', 'Error');

-- True when a LIVE payout for this advance is on its way or paid - then the advance can't be changed.
create or replace function public._cash_advance_payout_locked(p_advance_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (select 1 from public."XenditPayouts" x
                 where x."AdvanceID" = p_advance_id and not x."IsTest"
                   and x."Status" in ('Creating', 'ACCEPTED', 'REQUESTED', 'SUCCEEDED'));
$$;

revoke all on function public._cash_advance_payout_locked(uuid) from public, anon, authenticated;

create or replace function public._staff_has_payout_account(p_username text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((select su."PayoutChannelCode" is not null and su."PayoutAccountNumber" is not null and su."PayoutAccountName" is not null
                   from public."StaffUsers" su where su."Username" = p_username), false);
$$;

revoke all on function public._staff_has_payout_account(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Which employees can be paid by Xendit (Timesheets uses it for the Method dropdown). No account numbers.

create or replace function public.admin_list_payroll_payout_flags(p_admin_username text, p_admin_password text)
returns table(username text, pay_via_xendit boolean, has_account boolean)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select su."Username"::text, coalesce(su."PayViaXendit", false),
           (su."PayoutChannelCode" is not null and su."PayoutAccountNumber" is not null and su."PayoutAccountName" is not null)
    from public."StaffUsers" su;
end;
$$;

grant execute on function public.admin_list_payroll_payout_flags(text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_add_cash_advance (Payroll Setup log form): + Xendit (needs a payout account, saved Pending, no
-- on-hand check).

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

  if coalesce(p_method, 'Cash') not in ('Cash', 'Digital', 'Xendit') then
    return query select false, 'Method must be Cash, Digital or Xendit.'::text;
    return;
  end if;
  v_method := coalesce(p_method, 'Cash');

  if v_method = 'Xendit' then
    if not public._staff_has_payout_account(p_username) then
      return query select false, 'This employee has no payout account yet - add one in Payroll Setup (Edit > Salary Payout).'::text;
      return;
    end if;
  else
    v_balance := public.payroll_fund_balance(v_method);
    if p_amount > v_balance then
      return query select false,
        ('Insufficient ' || v_method || ' on Hand: this advance needs ' || to_char(p_amount, 'FM999,999,990.00') ||
         ', only ' || to_char(v_balance, 'FM999,999,990.00') || ' on hand. This will not go through - log a ' ||
         v_method || ' funding entry first.')::text;
      return;
    end if;
  end if;

  insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Notes", "Method", "Status", "CreatedBy")
  values (p_username, p_advance_date, p_amount, nullif(trim(p_notes), ''), v_method,
          case when v_method = 'Xendit' then 'Pending' else 'Outstanding' end, p_admin_username)
  returning "AdvanceID" into v_advance_id;

  insert into public."PayrollLedgerEntries"
    ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "SourceAdvanceID", "PostedBy")
  values (p_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', p_amount, v_method, v_advance_id, p_admin_username);

  return query select true, case when v_method = 'Xendit'
    then 'Cash advance logged - send it from Timesheets > Send Advances via Xendit.' else 'Cash advance logged.' end::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_upsert_cash_advances_bulk (Timesheets grid): + Xendit. Same two passes as
-- supabase_payroll_cash_advance_balance_guard.sql; Xendit advances don't touch the Cash/Digital simulation,
-- need a payout account, and one already sent through Xendit can't be changed.

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
  v_no_account text[] := '{}';
  v_locked text[] := '{}';
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_advance_date is null or p_week_start is null or p_week_end is null then
    return query select false, 'A valid advance date and week range are required.'::text;
    return;
  end if;

  -- Pass 1: validate (see supabase_payroll_cash_advance_balance_guard.sql).
  v_sim_cash := public.payroll_fund_balance('Cash');
  v_sim_digital := public.payroll_fund_balance('Digital');

  for v_entry in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb))
  loop
    v_username := v_entry->>'username';
    v_amount := round(coalesce(nullif(v_entry->>'amount', '')::numeric, 0), 2);
    v_method := v_entry->>'method';
    if coalesce(v_method, '') not in ('Cash', 'Digital', 'Xendit') then
      v_method := 'Cash';
    end if;

    select "DisplayName" into v_display_name from public."StaffUsers" where "Username" = v_username;
    if not found then
      continue;
    end if;

    v_existing_id := null;
    select "AdvanceID", "Amount", "Method" into v_existing_id, v_old_amount, v_old_method
      from public."PayrollCashAdvances"
      where "Username" = v_username and "Status" in ('Outstanding', 'Pending')
        and "AdvanceDate" between p_week_start and p_week_end
      order by "AdvanceDate"
      limit 1;

    if v_existing_id is not null and public._cash_advance_payout_locked(v_existing_id) then
      if v_amount <> v_old_amount or v_method <> v_old_method then
        v_locked := v_locked || coalesce(v_display_name, v_username);
      end if;
      continue;   -- sent / paid through Xendit: left exactly as it is
    end if;

    if v_amount > 0 and v_method = 'Xendit' and not public._staff_has_payout_account(v_username) then
      v_no_account := v_no_account || coalesce(v_display_name, v_username);
    end if;

    if v_existing_id is not null then
      if v_old_method = 'Cash' then v_sim_cash := v_sim_cash + v_old_amount;
      elsif v_old_method = 'Digital' then v_sim_digital := v_sim_digital + v_old_amount;
      end if;
    end if;
    if v_amount > 0 then
      if v_method = 'Cash' then v_sim_cash := v_sim_cash - v_amount;
      elsif v_method = 'Digital' then v_sim_digital := v_sim_digital - v_amount;
      end if;
    end if;
  end loop;

  if cardinality(v_locked) > 0 then
    return query select false,
      ('Already sent through Xendit, so it can''t be changed: ' || array_to_string(v_locked, ', ') ||
       '. Nothing was saved - put the amount and method back.')::text;
    return;
  end if;
  if cardinality(v_no_account) > 0 then
    return query select false,
      ('No Xendit payout account for: ' || array_to_string(v_no_account, ', ') ||
       '. Add it in Payroll Setup (Edit > Salary Payout) or pick Cash / Digital. Nothing was saved.')::text;
    return;
  end if;
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

  -- Pass 2: write.
  for v_entry in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb))
  loop
    v_username := v_entry->>'username';
    v_amount := round(coalesce(nullif(v_entry->>'amount', '')::numeric, 0), 2);
    v_method := v_entry->>'method';
    if coalesce(v_method, '') not in ('Cash', 'Digital', 'Xendit') then
      v_method := 'Cash';
    end if;

    select "DisplayName" into v_display_name from public."StaffUsers" where "Username" = v_username;
    if not found then
      continue;
    end if;

    v_existing_id := null;
    select "AdvanceID" into v_existing_id
      from public."PayrollCashAdvances"
      where "Username" = v_username and "Status" in ('Outstanding', 'Pending')
        and "AdvanceDate" between p_week_start and p_week_end
      order by "AdvanceDate"
      limit 1;

    if v_existing_id is not null and public._cash_advance_payout_locked(v_existing_id) then
      continue;
    end if;

    if v_amount > 0 then
      if v_existing_id is not null then
        -- A changed amount / method needs approving again (the SET expressions see the old values).
        update public."PayrollCashAdvances"
           set "Amount" = v_amount, "Method" = v_method,
               "Status" = case when v_method = 'Xendit' then 'Pending' else 'Outstanding' end,
               "SubmittedBy" = case when "Amount" = v_amount and "Method" = v_method then "SubmittedBy" end,
               "SubmittedAtUtc" = case when "Amount" = v_amount and "Method" = v_method then "SubmittedAtUtc" end
         where "AdvanceID" = v_existing_id;
        update public."PayrollLedgerEntries" set "Amount" = v_amount, "Method" = v_method where "SourceAdvanceID" = v_existing_id;
      else
        insert into public."PayrollCashAdvances" ("Username", "AdvanceDate", "Amount", "Method", "Status", "CreatedBy")
        values (v_username, p_advance_date, v_amount, v_method,
                case when v_method = 'Xendit' then 'Pending' else 'Outstanding' end, p_admin_username)
        returning "AdvanceID" into v_new_id;

        insert into public."PayrollLedgerEntries"
          ("Username", "DisplayName", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "SourceAdvanceID", "PostedBy")
        values (v_username, v_display_name, p_advance_date, p_advance_date, p_advance_date, 'CashAdvance', 'Cash Advance', v_amount, v_method, v_new_id, p_admin_username);
      end if;
    elsif v_existing_id is not null then
      delete from public."PayrollLedgerEntries" where "SourceAdvanceID" = v_existing_id;
      delete from public."PayrollCashAdvances" where "AdvanceID" = v_existing_id;
    end if;
  end loop;

  return query select true, 'Cash advances saved.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_delete_cash_advance: Outstanding or Pending, and not one already sent through Xendit.

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

  select "Status" into v_status from public."PayrollCashAdvances" where "AdvanceID" = p_advance_id for update;

  if v_status is null then
    return query select false, 'Cash advance not found.'::text;
    return;
  end if;

  if v_status not in ('Outstanding', 'Pending') then
    return query select false, ('Only an Outstanding or Pending cash advance can be deleted - this one is already ' || v_status || '.')::text;
    return;
  end if;

  if public._cash_advance_payout_locked(p_advance_id) then
    return query select false, 'This advance was already sent through Xendit, so it can''t be deleted.'::text;
    return;
  end if;

  delete from public."PayrollLedgerEntries" where "SourceAdvanceID" = p_advance_id;
  delete from public."PayrollCashAdvances" where "AdvanceID" = p_advance_id;

  return query select true, 'Cash advance deleted.'::text;
end;
$$;

grant execute on function public.admin_add_cash_advance(text, text, text, date, numeric, text, text) to anon;
grant execute on function public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb) to anon;
grant execute on function public.admin_delete_cash_advance(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- Submit for Approval (payroll officers + super users): marks the given Pending Xendit advances as submitted.
-- Ones with no payout account, already submitted, or already sent are skipped.

create or replace function public.admin_submit_cash_advances(p_admin_username text, p_admin_password text, p_advance_ids uuid[])
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_count int;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  update public."PayrollCashAdvances" a
     set "SubmittedBy" = p_admin_username, "SubmittedAtUtc" = now()
   where a."AdvanceID" = any(coalesce(p_advance_ids, '{}'))
     and a."Method" = 'Xendit' and a."Status" = 'Pending' and a."SubmittedAtUtc" is null
     and public._staff_has_payout_account(a."Username")
     and not public._cash_advance_payout_locked(a."AdvanceID");
  get diagnostics v_count = row_count;

  if v_count = 0 then
    return query select false, 'Nothing to submit - these advances are already submitted or sent.'::text;
    return;
  end if;
  return query select true, (v_count || ' advance' || case when v_count = 1 then '' else 's' end ||
                             ' submitted - a super user can now approve and send.')::text;
end;
$$;

grant execute on function public.admin_submit_cash_advances(text, text, uuid[]) to anon;

-- ---------------------------------------------------------------------------
-- Xendit advances to show in Timesheets > Send Advances via Xendit: every Pending one (any date) plus the week's
-- other Xendit advances, each with its latest payout (live first) and who submitted it.

drop function if exists public.admin_list_cash_advance_payouts(text, text, date, date);

create or replace function public.admin_list_cash_advance_payouts(p_admin_username text, p_admin_password text, p_week_start date, p_week_end date)
returns table(advance_id uuid, username text, display_name text, advance_date date, amount numeric, advance_status text,
              submitted_by text, submitted_at timestamptz,
              has_account boolean, channel_name text, account_masked text, account_name text,
              payout_id uuid, status text, is_test boolean, failure text, sent_by text, sent_at timestamptz,
              paid_at timestamptz, payout_channel text, payout_account_masked text)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select a."AdvanceID", a."Username"::text, su."DisplayName"::text, a."AdvanceDate", a."Amount", a."Status"::text,
           a."SubmittedBy", a."SubmittedAtUtc",
           (su."PayoutChannelCode" is not null and su."PayoutAccountNumber" is not null and su."PayoutAccountName" is not null),
           coalesce(su."PayoutChannelName", su."PayoutChannelCode"),
           case when su."PayoutAccountNumber" is null then null else '••' || right(su."PayoutAccountNumber", 4) end,
           su."PayoutAccountName",
           p."PayoutID", p."Status", p."IsTest", coalesce(p."FailureCode", p."Error"), p."SentBy", p."CreatedAtUtc",
           p."PaidAtUtc", coalesce(p."ChannelName", p."ChannelCode"),
           case when p."AccountNumber" is null then null else '••' || right(p."AccountNumber", 4) end
    from public."PayrollCashAdvances" a
    left join public."StaffUsers" su on su."Username" = a."Username"
    left join lateral (
      select x.* from public."XenditPayouts" x where x."AdvanceID" = a."AdvanceID"
      order by x."IsTest", x."CreatedAtUtc" desc limit 1
    ) p on true
    where (a."Method" = 'Xendit' and (a."Status" = 'Pending' or a."AdvanceDate" between p_week_start and p_week_end))
       or (p."PayoutID" is not null and a."AdvanceDate" between p_week_start and p_week_end)
    order by a."AdvanceDate", su."DisplayName", a."Username";
end;
$$;

grant execute on function public.admin_list_cash_advance_payouts(text, text, date, date) to anon;

-- ---------------------------------------------------------------------------
-- Service-role helpers for xendit-payroll-payout.

-- Rows to send for the given advances, in this mode: a new row per Pending Xendit advance with nothing going yet
-- (account copied from StaffUsers now), plus any row stuck at 'Creating' (re-sent with the SAME Idempotency-key).
create or replace function public._advance_payouts_prepare(p_is_test boolean, p_sent_by text, p_advance_ids uuid[])
returns table(payout_id uuid, reference_id text, line_id uuid, display_name text, amount numeric, channel_code text,
              account_number text, account_name text, description text, is_new boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  a record;
  v_id uuid;
  v_desc text;
begin
  perform pg_advisory_xact_lock(hashtext('payroll-advance-payout'));

  for a in
    select ca.*, su."DisplayName" as display_name, su."PayoutChannelCode", su."PayoutChannelName", su."PayoutAccountNumber", su."PayoutAccountName"
    from public."PayrollCashAdvances" ca
    left join public."StaffUsers" su on su."Username" = ca."Username"
    where ca."AdvanceID" = any(coalesce(p_advance_ids, '{}'))
      and ca."Method" = 'Xendit' and ca."Status" = 'Pending'
      and ca."SubmittedAtUtc" is not null   -- only advances a payroll officer submitted for approval
    for update of ca
  loop
    v_desc := left('Cash advance ' || to_char(a."AdvanceDate", 'Mon DD YYYY') || ' RS Pet Stop', 100);

    select x."PayoutID" into v_id from public."XenditPayouts" x
     where x."AdvanceID" = a."AdvanceID" and x."IsTest" = p_is_test and x."Status" not in ('FAILED', 'CANCELLED', 'REVERSED', 'Error');
    if found then
      if exists (select 1 from public."XenditPayouts" x where x."PayoutID" = v_id and x."Status" = 'Creating') then
        return query
          select x."PayoutID", x."ReferenceID", null::uuid, x."DisplayName", x."Amount", x."ChannelCode", x."AccountNumber", x."AccountName", v_desc, false
          from public."XenditPayouts" x where x."PayoutID" = v_id;
      end if;
      continue;
    end if;

    if a."PayoutChannelCode" is null or a."PayoutAccountNumber" is null or a."PayoutAccountName" is null then
      raise exception '% has no payout account - add it in Payroll Setup (Edit > Salary Payout).', coalesce(a.display_name, a."Username");
    end if;

    v_id := gen_random_uuid();
    insert into public."XenditPayouts" ("PayoutID", "ReferenceID", "Kind", "AdvanceID", "Username", "DisplayName", "Amount",
                                        "ChannelCode", "ChannelName", "AccountNumber", "AccountName", "IsTest", "SentBy")
    values (v_id, 'RSPS-PAY-' || replace(v_id::text, '-', ''), 'Advance', a."AdvanceID", a."Username", a.display_name, a."Amount",
            a."PayoutChannelCode", a."PayoutChannelName", a."PayoutAccountNumber", a."PayoutAccountName", p_is_test, p_sent_by);

    return query
      select v_id, 'RSPS-PAY-' || replace(v_id::text, '-', ''), null::uuid, a.display_name::text, a."Amount",
             a."PayoutChannelCode"::text, a."PayoutAccountNumber"::text, a."PayoutAccountName"::text, v_desc, true;
  end loop;
end;
$$;

revoke all on function public._advance_payouts_prepare(boolean, text, uuid[]) from public, anon, authenticated;
grant execute on function public._advance_payouts_prepare(boolean, text, uuid[]) to service_role;

-- Advance payouts still waiting on Xendit (for "Refresh Status").
create or replace function public._advance_payouts_open()
returns table(payout_id uuid, reference_id text, xendit_payout_id text, is_test boolean, status text, age_seconds numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select "PayoutID", "ReferenceID", "XenditPayoutID", "IsTest", "Status", extract(epoch from now() - "CreatedAtUtc")::numeric
  from public."XenditPayouts"
  where "Kind" = 'Advance' and "Status" in ('Creating', 'ACCEPTED', 'REQUESTED');
$$;

revoke all on function public._advance_payouts_open() from public, anon, authenticated;
grant execute on function public._advance_payouts_open() to service_role;

-- _payroll_payout_record: same as supabase_xendit_payroll_payouts.sql, plus - for a LIVE advance payout -
-- SUCCEEDED turns the advance Outstanding (deducted by the next payroll run); FAILED / CANCELLED / REVERSED turns
-- an Outstanding (not yet deducted) one back to Pending, unless another live payout for it is going / paid.
create or replace function public._payroll_payout_record(
  p_payout_id uuid,
  p_reference_id text,
  p_status text,
  p_xendit_id text,
  p_failure_code text,
  p_error text,
  p_estimated_arrival timestamptz,
  p_body jsonb
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."XenditPayouts"%rowtype;
  v_status text := upper(nullif(trim(coalesce(p_status, '')), ''));
begin
  select * into v_row from public."XenditPayouts"
   where (p_payout_id is not null and "PayoutID" = p_payout_id) or (p_reference_id is not null and "ReferenceID" = p_reference_id)
   limit 1
   for update;
  if not found then
    return 'not found';
  end if;

  if v_status is null then
    if p_error is not null and v_row."Status" = 'Creating' and v_row."XenditPayoutID" is null then
      update public."XenditPayouts" set "Status" = 'Error', "Error" = left(p_error, 500), "UpdatedAtUtc" = now(),
             "LastResponse" = coalesce(p_body, "LastResponse")
       where "PayoutID" = v_row."PayoutID";
      return 'Error';
    end if;
    return v_row."Status";
  end if;

  if v_row."Status" in ('SUCCEEDED', 'FAILED', 'CANCELLED', 'REVERSED') and v_status in ('ACCEPTED', 'REQUESTED') then
    return v_row."Status";
  end if;

  update public."XenditPayouts"
     set "Status" = v_status,
         "XenditPayoutID" = coalesce(nullif(p_xendit_id, ''), "XenditPayoutID"),
         "FailureCode" = case when v_status in ('FAILED', 'CANCELLED', 'REVERSED') then coalesce(nullif(p_failure_code, ''), "FailureCode") else "FailureCode" end,
         "Error" = null,
         "EstimatedArrivalUtc" = coalesce(p_estimated_arrival, "EstimatedArrivalUtc"),
         "PaidAtUtc" = case when v_status = 'SUCCEEDED' then coalesce("PaidAtUtc", now()) else "PaidAtUtc" end,
         "UpdatedAtUtc" = now(),
         "LastResponse" = coalesce(p_body, "LastResponse")
   where "PayoutID" = v_row."PayoutID";

  if v_row."Kind" = 'Advance' and v_row."AdvanceID" is not null and not v_row."IsTest" then
    if v_status = 'SUCCEEDED' then
      update public."PayrollCashAdvances" set "Status" = 'Outstanding'
       where "AdvanceID" = v_row."AdvanceID" and "Status" = 'Pending';
    elsif v_status in ('FAILED', 'CANCELLED', 'REVERSED') then
      update public."PayrollCashAdvances" set "Status" = 'Pending'
       where "AdvanceID" = v_row."AdvanceID" and "Status" = 'Outstanding'
         and not exists (select 1 from public."XenditPayouts" x
                         where x."AdvanceID" = v_row."AdvanceID" and not x."IsTest" and x."PayoutID" <> v_row."PayoutID"
                           and x."Status" in ('Creating', 'ACCEPTED', 'REQUESTED', 'SUCCEEDED'));
    end if;
  end if;

  return v_status;
end;
$$;

revoke all on function public._payroll_payout_record(uuid, text, text, text, text, text, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public._payroll_payout_record(uuid, text, text, text, text, text, timestamptz, jsonb) to service_role;

notify pgrst, 'reload schema';

-- Check - one result.
select 'advance status' as section,
       case when pg_get_constraintdef((select oid from pg_constraint where conname = 'CK_PayrollCashAdvances_Status')) like '%Pending%'
            then 'Pending allowed' else 'MISSING' end as value
union all
select 'advance method',
       case when pg_get_constraintdef((select oid from pg_constraint where conname = 'CK_PayrollCashAdvances_Method')) like '%Xendit%'
            then 'Xendit allowed' else 'MISSING' end
union all
select 'payouts table', case when exists (select 1 from information_schema.columns where table_name = 'XenditPayouts' and column_name = 'AdvanceID')
                             then 'XenditPayouts takes advances' else 'MISSING - run supabase_xendit_payroll_payouts.sql first' end
union all
select 'bulk save', case when pg_get_functiondef('public.admin_upsert_cash_advances_bulk(text, text, date, date, date, jsonb)'::regprocedure) like '%_cash_advance_payout_locked%'
                         then 'Timesheets save knows Xendit' else 'OLD version' end
union all
select 'approval', case when to_regprocedure('public.admin_submit_cash_advances(text, text, uuid[])') is not null
                        then 'Submit for Approval ready' else 'MISSING' end
union all
select 'xendit advances pending', count(*)::text from public."PayrollCashAdvances" where "Status" = 'Pending';
