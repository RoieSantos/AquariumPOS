-- Payroll: pay salaries through Xendit (GCash / bank) - per "i want to automate my salary dispensing on my
-- portal using xendit" ... "Gcash and bank accounts" ... "the salary will be coming in from the sales so no need
-- to topup unless money is not enough".
--
--   - Each employee can have a payout account (Payroll Setup > Edit > Salary Payout): GCash / Maya / bank, the
--     account number and name, and "Pay salary via Xendit". Super users only - a changed number redirects pay.
--   - A payroll line's pay method can now be Cash, Digital or Xendit. An employee with "Pay via Xendit" on starts
--     as Xendit; the Lines dropdown still changes it for one run. Employees' own Cash/Digital default, cash
--     advances and the Cash / Digital on Hand buckets are unchanged.
--   - Xendit lines are paid from the Xendit sales balance, so Finalize doesn't need Digital on Hand for them; it
--     only checks each has a payout account, and posts their total as a "Payroll Payout" with Method 'Xendit'
--     (which no on-hand bucket counts).
--   - After Finalize, a super user sends the payouts (Payroll Run > Pay via Xendit, Edge Function
--     xendit-payroll-payout). One XenditPayouts row per line per mode; its PayoutID is Xendit's Idempotency-key,
--     so a double click or a retry can't pay twice. Xendit's payout webhook (xendit-webhook) marks them
--     Succeeded / Failed; a failed one can be sent again after fixing the account.
--
-- Run AFTER supabase_payroll_run_line_method_override.sql (replaces its admin_set_payroll_run_line_method,
-- admin_list_payroll_run_lines, admin_get_payroll_run_funding_requirement and admin_finalize_payroll_run).
-- Safe to re-run. Needs js/payrollRun.js ?v=xpayout1, js/payrollSetup.js ?v=xpayout1, js/payrollLedger.js
-- ?v=xpayout1 and the xendit-payroll-payout + xendit-webhook Edge Functions. Ends with ONE result.

-- ---------------------------------------------------------------------------
-- Employee payout account (StaffUsers is service-only: RLS on, no anon grants).

alter table public."StaffUsers" add column if not exists "PayViaXendit" boolean not null default false;
alter table public."StaffUsers" add column if not exists "PayoutChannelCode" text;     -- Xendit channel_code, e.g. PH_GCASH, PH_BPI
alter table public."StaffUsers" add column if not exists "PayoutChannelName" text;     -- e.g. GCash, Bank of the Philippine Islands
alter table public."StaffUsers" add column if not exists "PayoutAccountNumber" text;
alter table public."StaffUsers" add column if not exists "PayoutAccountName" text;
alter table public."StaffUsers" add column if not exists "PayoutUpdatedBy" text;
alter table public."StaffUsers" add column if not exists "PayoutUpdatedAtUtc" timestamptz;

-- ---------------------------------------------------------------------------
-- 'Xendit' as a line method and a ledger method.

alter table public."PayrollRunLines" drop constraint if exists "CK_PayrollRunLines_PaymentMethod";
alter table public."PayrollRunLines"
  add constraint "CK_PayrollRunLines_PaymentMethod" check ("PaymentMethod" is null or "PaymentMethod" in ('Cash', 'Digital', 'Xendit'));

alter table public."PayrollLedgerEntries" drop constraint if exists "CK_PayrollLedgerEntries_Method";
alter table public."PayrollLedgerEntries"
  add constraint "CK_PayrollLedgerEntries_Method" check ("Method" is null or "Method" in ('Cash', 'Digital', 'Xendit'));

-- A line's method: its own (set in the run, or stamped at Finalize), else Xendit for a "Pay via Xendit"
-- employee, else the employee's Cash/Digital default, else Cash.
create or replace function public._payroll_line_method(p_line_method text, p_staff_method text, p_pay_via_xendit boolean)
returns text
language sql
immutable
as $$
  select coalesce(p_line_method, case when p_pay_via_xendit then 'Xendit' end, p_staff_method, 'Cash');
$$;

-- ---------------------------------------------------------------------------
-- Payouts sent through Xendit.

create table if not exists public."XenditPayouts" (
  "PayoutID" uuid primary key default gen_random_uuid(),   -- also Xendit's Idempotency-key
  "ReferenceID" text not null unique,                      -- 'RSPS-PAY-<PayoutID without dashes>'
  "RunID" uuid not null references public."PayrollRuns" ("RunID"),
  "LineID" uuid not null references public."PayrollRunLines" ("LineID"),
  "Username" text,
  "DisplayName" text,
  "Amount" numeric(18, 2) not null check ("Amount" > 0),
  "ChannelCode" text not null,
  "ChannelName" text,
  "AccountNumber" text not null,
  "AccountName" text not null,
  "IsTest" boolean not null,
  "Status" text not null default 'Creating',  -- Creating / ACCEPTED / REQUESTED / SUCCEEDED / FAILED / CANCELLED / REVERSED / Error
  "XenditPayoutID" text unique,
  "FailureCode" text,
  "Error" text,
  "EstimatedArrivalUtc" timestamptz,
  "SentBy" text not null,
  "CreatedAtUtc" timestamptz not null default now(),
  "UpdatedAtUtc" timestamptz,
  "PaidAtUtc" timestamptz,
  "LastResponse" jsonb
);

-- One live payout per line that is still going or done (and one test). A failed / cancelled / reversed /
-- rejected one doesn't count, so it can be sent again.
create unique index if not exists "UX_XenditPayouts_ActiveLine" on public."XenditPayouts" ("LineID", "IsTest")
  where "Status" not in ('FAILED', 'CANCELLED', 'REVERSED', 'Error');
create index if not exists "IX_XenditPayouts_RunID" on public."XenditPayouts" ("RunID");

alter table public."XenditPayouts" enable row level security;
revoke all on public."XenditPayouts" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Payout account: read / save (super users only).

create or replace function public.admin_get_payroll_payout_account(p_admin_username text, p_admin_password text, p_username text)
returns table(pay_via_xendit boolean, channel_code text, channel_name text, account_number text, account_name text,
              updated_by text, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  return query
    select su."PayViaXendit", su."PayoutChannelCode", su."PayoutChannelName", su."PayoutAccountNumber", su."PayoutAccountName",
           su."PayoutUpdatedBy", su."PayoutUpdatedAtUtc"
    from public."StaffUsers" su where su."Username" = p_username;
end;
$$;

grant execute on function public.admin_get_payroll_payout_account(text, text, text) to anon;

drop function if exists public.admin_set_payroll_payout_account(text, text, text, boolean, text, text, text, text);

create or replace function public.admin_set_payroll_payout_account(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_pay_via_xendit boolean,
  p_channel_code text,
  p_channel_name text,
  p_account_number text,
  p_account_name text
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(nullif(trim(coalesce(p_channel_code, '')), ''));
  v_number text := nullif(regexp_replace(coalesce(p_account_number, ''), '[\s-]', '', 'g'), '');
  v_name text := nullif(left(regexp_replace(trim(coalesce(p_account_name, '')), '\s+', ' ', 'g'), 100), '');
  v_wallet boolean;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Only a super user can change payout accounts.'::text;
    return;
  end if;
  if not exists (select 1 from public."StaffUsers" where "Username" = p_username) then
    return query select false, 'Employee not found.'::text;
    return;
  end if;

  if v_code is not null or v_number is not null or v_name is not null or coalesce(p_pay_via_xendit, false) then
    if v_code is null or v_number is null or v_name is null then
      return query select false, 'Pick where to pay, and enter the account number and the account name.'::text;
      return;
    end if;
    if v_code !~ '^[A-Z0-9_]{3,40}$' then
      return query select false, 'Unknown payout channel.'::text;
      return;
    end if;
    v_wallet := v_code in ('PH_GCASH', 'PH_PAYMAYA', 'PH_GRABPAY', 'PH_SHOPEEPAY');
    if v_wallet then
      v_number := regexp_replace(v_number, '^(\+?63)', '0');
      if v_number !~ '^09[0-9]{9}$' then
        return query select false, 'Enter the 11-digit mobile number of the wallet, e.g. 09171234567.'::text;
        return;
      end if;
    elsif v_number !~ '^[0-9]{6,20}$' then
      return query select false, 'A bank account number is 6 to 20 digits.'::text;
      return;
    end if;
  end if;

  update public."StaffUsers"
     set "PayViaXendit" = coalesce(p_pay_via_xendit, false) and v_code is not null,
         "PayoutChannelCode" = v_code,
         "PayoutChannelName" = case when v_code is null then null else nullif(left(trim(coalesce(p_channel_name, '')), 120), '') end,
         "PayoutAccountNumber" = v_number,
         "PayoutAccountName" = v_name,
         "PayoutUpdatedBy" = p_admin_username,
         "PayoutUpdatedAtUtc" = now()
   where "Username" = p_username;

  return query select true, case when v_code is null then 'Payout account removed.' else 'Payout account saved.' end::text;
end;
$$;

grant execute on function public.admin_set_payroll_payout_account(text, text, text, boolean, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- admin_set_payroll_run_line_method: + 'Xendit' (only for an employee with a payout account).

create or replace function public.admin_set_payroll_run_line_method(p_admin_username text, p_admin_password text, p_line_id uuid, p_method text)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_has_account boolean;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_method is null or p_method not in ('Cash', 'Digital', 'Xendit') then
    return query select false, 'Method must be Cash, Digital or Xendit.'::text;
    return;
  end if;

  select r."Status", (su."PayoutChannelCode" is not null and su."PayoutAccountNumber" is not null and su."PayoutAccountName" is not null)
    into v_status, v_has_account
  from public."PayrollRunLines" l
  join public."PayrollRuns" r on r."RunID" = l."RunID"
  left join public."StaffUsers" su on su."Username" = l."Username"
  where l."LineID" = p_line_id;

  if v_status is null then
    return query select false, 'Payroll line not found.'::text;
    return;
  end if;
  if v_status = 'Finalized' then
    return query select false, 'This payroll run is already finalized.'::text;
    return;
  end if;
  if p_method = 'Xendit' and not coalesce(v_has_account, false) then
    return query select false, 'This employee has no payout account yet - add one in Payroll Setup (Edit > Salary Payout).'::text;
    return;
  end if;

  update public."PayrollRunLines" set "PaymentMethod" = p_method where "LineID" = p_line_id;

  return query select true, 'Pay method updated.'::text;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list_payroll_run_lines: same columns; payment_method can now be Xendit.

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
           public._payroll_line_method(l."PaymentMethod", su."PaymentMethod", coalesce(su."PayViaXendit", false))::text
    from public."PayrollRunLines" l
    left join public."StaffUsers" su on su."Username" = l."Username"
    where l."RunID" = p_run_id
    order by l."DisplayName", l."Username";
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_get_payroll_run_funding_requirement: + xendit_required (paid from the Xendit balance, checked when
-- sending, not at Finalize).

drop function if exists public.admin_get_payroll_run_funding_requirement(text, text, uuid);

create or replace function public.admin_get_payroll_run_funding_requirement(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(cash_required numeric, digital_required numeric, cash_balance numeric, digital_balance numeric, xendit_required numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with m as (
      select l."NetPay", public._payroll_line_method(l."PaymentMethod", su."PaymentMethod", coalesce(su."PayViaXendit", false)) as method
      from public."PayrollRunLines" l
      join public."StaffUsers" su on su."Username" = l."Username"
      where l."RunID" = p_run_id
    )
    select
      coalesce((select sum("NetPay") from m where method = 'Cash'), 0),
      coalesce((select sum("NetPay") from m where method = 'Digital'), 0),
      public.payroll_fund_balance('Cash'),
      public.payroll_fund_balance('Digital'),
      coalesce((select sum("NetPay") from m where method = 'Xendit'), 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_finalize_payroll_run: Xendit lines skip the on-hand checks but need a payout account; their total
-- posts as a Payroll Payout with Method 'Xendit'. Otherwise the same as
-- supabase_payroll_run_line_method_override.sql.

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
  v_xendit_required numeric;
  v_cash_balance numeric;
  v_digital_balance numeric;
  v_no_account text;
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

  -- Stamp every line's method first, so the checks and the postings below read one value.
  update public."PayrollRunLines" l
    set "PaymentMethod" = public._payroll_line_method(l."PaymentMethod", su."PaymentMethod", coalesce(su."PayViaXendit", false))
    from public."StaffUsers" su
    where su."Username" = l."Username" and l."RunID" = p_run_id;

  select string_agg(coalesce(l."DisplayName", l."Username"), ', ' order by l."DisplayName")
    into v_no_account
    from public."PayrollRunLines" l
    left join public."StaffUsers" su on su."Username" = l."Username"
    where l."RunID" = p_run_id and l."PaymentMethod" = 'Xendit' and l."NetPay" > 0
      and (su."PayoutChannelCode" is null or su."PayoutAccountNumber" is null or su."PayoutAccountName" is null);
  if v_no_account is not null then
    raise exception 'No Xendit payout account for: %. Add it in Payroll Setup (Edit > Salary Payout) or change the line to Cash / Digital.', v_no_account;
  end if;

  select coalesce(sum(l."NetPay") filter (where l."PaymentMethod" = 'Cash'), 0),
         coalesce(sum(l."NetPay") filter (where l."PaymentMethod" = 'Digital'), 0),
         coalesce(sum(l."NetPay") filter (where l."PaymentMethod" = 'Xendit'), 0)
    into v_cash_required, v_digital_required, v_xendit_required
    from public."PayrollRunLines" l
    where l."RunID" = p_run_id;

  v_cash_balance := public.payroll_fund_balance('Cash');
  v_digital_balance := public.payroll_fund_balance('Digital');

  -- A refusal raises (not "return false") so the stamped methods above roll back with it.
  if v_cash_required > v_cash_balance then
    raise exception 'Insufficient Cash on Hand: need %, have %. Log a Cash funding entry in Payroll Setup first.',
      to_char(v_cash_required, 'FM999,999,990.00'), to_char(v_cash_balance, 'FM999,999,990.00');
  end if;

  if v_digital_required > v_digital_balance then
    raise exception 'Insufficient Digital on Hand: need %, have %. Log a Digital funding entry in Payroll Setup first.',
      to_char(v_digital_required, 'FM999,999,990.00'), to_char(v_digital_balance, 'FM999,999,990.00');
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

  if v_xendit_required > 0 then
    insert into public."PayrollLedgerEntries"
      ("RunID", "PayCycle", "PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Amount", "Method", "PostedBy")
    values (p_run_id, v_pay_cycle, v_period_start, v_period_end, v_pay_date, 'Payroll', 'Payroll Payout (Xendit)', v_xendit_required, 'Xendit', p_admin_username);
  end if;

  return query select true, 'Payroll run finalized.'::text;
end;
$$;

grant execute on function public.admin_set_payroll_run_line_method(text, text, uuid, text) to anon;
grant execute on function public.admin_list_payroll_run_lines(text, text, uuid) to anon;
grant execute on function public.admin_get_payroll_run_funding_requirement(text, text, uuid) to anon;
grant execute on function public.admin_finalize_payroll_run(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- The run's Xendit lines and each one's latest payout (payroll officers can see; only super users send).

create or replace function public.admin_list_payroll_run_payouts(p_admin_username text, p_admin_password text, p_run_id uuid)
returns table(line_id uuid, username text, display_name text, net_pay numeric, has_account boolean,
              channel_code text, channel_name text, account_masked text, account_name text,
              payout_id uuid, status text, is_test boolean, failure text, sent_by text, sent_at timestamptz,
              paid_at timestamptz, estimated_arrival timestamptz, payout_channel text, payout_account_masked text)
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
    select l."LineID", l."Username"::text, l."DisplayName"::text, l."NetPay",
           (su."PayoutChannelCode" is not null and su."PayoutAccountNumber" is not null and su."PayoutAccountName" is not null),
           su."PayoutChannelCode", coalesce(su."PayoutChannelName", su."PayoutChannelCode"),
           case when su."PayoutAccountNumber" is null then null else '••' || right(su."PayoutAccountNumber", 4) end,
           su."PayoutAccountName",
           p."PayoutID", p."Status", p."IsTest", coalesce(p."FailureCode", p."Error"), p."SentBy", p."CreatedAtUtc",
           p."PaidAtUtc", p."EstimatedArrivalUtc",
           coalesce(p."ChannelName", p."ChannelCode"),
           case when p."AccountNumber" is null then null else '••' || right(p."AccountNumber", 4) end
    from public."PayrollRunLines" l
    left join public."StaffUsers" su on su."Username" = l."Username"
    left join lateral (
      select x.* from public."XenditPayouts" x where x."LineID" = l."LineID"
      order by x."IsTest", x."CreatedAtUtc" desc limit 1      -- live ahead of test, newest first
    ) p on true
    where l."RunID" = p_run_id
      and public._payroll_line_method(l."PaymentMethod", su."PaymentMethod", coalesce(su."PayViaXendit", false)) = 'Xendit'
    order by l."DisplayName", l."Username";
end;
$$;

grant execute on function public.admin_list_payroll_run_payouts(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- Service-role helpers for the Edge Functions.

-- Rows to send for a finalized run, in this mode: a new row per Xendit line with nothing going yet (account copied
-- from StaffUsers now), plus any row stuck at 'Creating' (a call that didn't answer) so it's re-sent with the
-- SAME Idempotency-key. Lines already sent / paid are skipped.
drop function if exists public._payroll_payouts_prepare(uuid, boolean, text, uuid[]);

create or replace function public._payroll_payouts_prepare(p_run_id uuid, p_is_test boolean, p_sent_by text, p_line_ids uuid[] default null)
returns table(payout_id uuid, reference_id text, line_id uuid, display_name text, amount numeric, channel_code text,
              account_number text, account_name text, description text, is_new boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_run public."PayrollRuns"%rowtype;
  l record;
  v_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext('payroll-payout:' || p_run_id::text));

  select * into v_run from public."PayrollRuns" where "RunID" = p_run_id;
  if not found then
    raise exception 'Payroll run not found.';
  end if;
  if v_run."Status" <> 'Finalized' then
    raise exception 'Finalize the payroll run before sending payouts.';
  end if;

  for l in
    select pl.*, su."PayoutChannelCode", su."PayoutChannelName", su."PayoutAccountNumber", su."PayoutAccountName"
    from public."PayrollRunLines" pl
    left join public."StaffUsers" su on su."Username" = pl."Username"
    where pl."RunID" = p_run_id and pl."PaymentMethod" = 'Xendit' and pl."NetPay" > 0
      and (p_line_ids is null or pl."LineID" = any(p_line_ids))
  loop
    select x."PayoutID" into v_id from public."XenditPayouts" x
     where x."LineID" = l."LineID" and x."IsTest" = p_is_test and x."Status" not in ('FAILED', 'CANCELLED', 'REVERSED', 'Error');
    if found then
      if exists (select 1 from public."XenditPayouts" x where x."PayoutID" = v_id and x."Status" = 'Creating') then
        return query
          select x."PayoutID", x."ReferenceID", x."LineID", x."DisplayName", x."Amount", x."ChannelCode", x."AccountNumber", x."AccountName",
                 left('Salary ' || to_char(v_run."PeriodStart", 'Mon DD') || '-' || to_char(v_run."PeriodEnd", 'Mon DD YYYY') || ' RS Pet Stop', 100), false
          from public."XenditPayouts" x where x."PayoutID" = v_id;
      end if;
      continue;
    end if;

    if l."PayoutChannelCode" is null or l."PayoutAccountNumber" is null or l."PayoutAccountName" is null then
      raise exception '% has no payout account - add it in Payroll Setup (Edit > Salary Payout).', coalesce(l."DisplayName", l."Username");
    end if;

    v_id := gen_random_uuid();
    insert into public."XenditPayouts" ("PayoutID", "ReferenceID", "RunID", "LineID", "Username", "DisplayName", "Amount",
                                        "ChannelCode", "ChannelName", "AccountNumber", "AccountName", "IsTest", "SentBy")
    values (v_id, 'RSPS-PAY-' || replace(v_id::text, '-', ''), p_run_id, l."LineID", l."Username", l."DisplayName", round(l."NetPay", 2),
            l."PayoutChannelCode", l."PayoutChannelName", l."PayoutAccountNumber", l."PayoutAccountName", p_is_test, p_sent_by);

    return query
      select v_id, 'RSPS-PAY-' || replace(v_id::text, '-', ''), l."LineID", l."DisplayName"::text, round(l."NetPay", 2),
             l."PayoutChannelCode", l."PayoutAccountNumber", l."PayoutAccountName",
             left('Salary ' || to_char(v_run."PeriodStart", 'Mon DD') || '-' || to_char(v_run."PeriodEnd", 'Mon DD YYYY') || ' RS Pet Stop', 100), true;
  end loop;
end;
$$;

revoke all on function public._payroll_payouts_prepare(uuid, boolean, text, uuid[]) from public, anon, authenticated;
grant execute on function public._payroll_payouts_prepare(uuid, boolean, text, uuid[]) to service_role;

-- Records what Xendit said about a payout (create answer, status read, or webhook). Found by PayoutID or by
-- ReferenceID. p_status null + p_error = Xendit refused to create it (marked 'Error', can be sent again). A
-- final status is never moved back to an in-progress one (webhooks can arrive out of order).
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
  return v_status;
end;
$$;

revoke all on function public._payroll_payout_record(uuid, text, text, text, text, text, timestamptz, jsonb) from public, anon, authenticated;
grant execute on function public._payroll_payout_record(uuid, text, text, text, text, text, timestamptz, jsonb) to service_role;

-- Payouts of a run still waiting on Xendit (for "Refresh status").
drop function if exists public._payroll_payouts_open(uuid);

create or replace function public._payroll_payouts_open(p_run_id uuid)
returns table(payout_id uuid, reference_id text, xendit_payout_id text, is_test boolean, status text, age_seconds numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select "PayoutID", "ReferenceID", "XenditPayoutID", "IsTest", "Status", extract(epoch from now() - "CreatedAtUtc")::numeric
  from public."XenditPayouts"
  where "RunID" = p_run_id and "Status" in ('Creating', 'ACCEPTED', 'REQUESTED');
$$;

revoke all on function public._payroll_payouts_open(uuid) from public, anon, authenticated;
grant execute on function public._payroll_payouts_open(uuid) to service_role;

notify pgrst, 'reload schema';

-- Check - one result.
select 'columns' as section,
       (select count(*) from information_schema.columns where table_name = 'StaffUsers' and column_name in
         ('PayViaXendit', 'PayoutChannelCode', 'PayoutChannelName', 'PayoutAccountNumber', 'PayoutAccountName'))::text || ' of 5 payout columns on StaffUsers' as value
union all
select 'table', case when to_regclass('public."XenditPayouts"') is not null then 'XenditPayouts ready' else 'XenditPayouts MISSING' end
union all
select 'finalize', case when pg_get_functiondef('public.admin_finalize_payroll_run(text, text, uuid)'::regprocedure) like '%Payroll Payout (Xendit)%'
                        then 'Finalize knows Xendit lines' else 'Finalize is the OLD version' end
union all
select 'employees on Xendit', count(*)::text from public."StaffUsers" where "PayViaXendit";
