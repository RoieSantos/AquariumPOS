-- Payout receipts for salary and cash advances sent through Xendit - per "Do we have a receipt that we can tag to
-- the employee if the cashadvance and salary has been sent?" ... "yes 1 and 2 then notice can be on the portal".
--
--   - New page payout-receipt.html?id=<PayoutID>: one salary or cash advance payout - reference, Xendit payout ID,
--     date paid, employee, amount, what it was for (pay period / advance date), where it went (GCash / bank, account
--     masked to the last 4) and who sent it. Login required: the employee sees their OWN live payouts only; payroll
--     officers and super users see any (test ones marked TEST). Owner withdrawals (Kind 'Owner') never show here.
--   - My Payslips: a Receipt button on each salary paid via Xendit, plus a "Cash Advances Sent via Xendit" list.
--   - Payroll Run / Timesheets: a Receipt link next to every Paid payout.
--   - Portal notice: when Xendit confirms a payout (SUCCEEDED, live), the employee sees a banner under the top nav on
--     every portal page until they open the receipt or click Dismiss (XenditPayouts.EmployeeSeenAtUtc). Only payouts
--     paid in the last 14 days show as notices, so older ones don't all pop up at once.
--   - Per Xendit support: GCash / banks print their own Ref No. (not returned by the API) and the sending partner bank
--     can vary, so the receipt matches by amount + Philippine time, and also shows the payout description.
--
-- Run AFTER supabase_xendit_cash_advance_payouts.sql. Safe to re-run. No Edge Function change. Needs
-- payout-receipt.html, js/payoutReceipt.js, js/myPayslips.js ?v=receipt1, js/nav.js ?v=payoutnotice1,
-- js/auth.js ?v=payoutreceipt1, js/payrollRun.js ?v=receipt1, js/payrollTimesheets.js ?v=receipt1. Ends with ONE result.

alter table public."XenditPayouts" add column if not exists "EmployeeSeenAtUtc" timestamptz;

create index if not exists "IX_XenditPayouts_Username" on public."XenditPayouts" ("Username") where "Kind" in ('Salary', 'Advance');

-- ---------------------------------------------------------------------------
-- One receipt. Opening your own paid receipt also clears its portal notice.

drop function if exists public.my_get_payout_receipt(text, text, uuid);

create or replace function public.my_get_payout_receipt(p_username text, p_password text, p_payout_id uuid)
returns table(payout_id uuid, reference_id text, kind text, status text, is_test boolean, is_mine boolean,
              username text, display_name text, amount numeric, channel_name text, account_name text,
              account_masked text, xendit_payout_id text, failure text, sent_by text, sent_at timestamptz,
              paid_at timestamptz, line_id uuid, pay_cycle text, period_start date, period_end date, pay_date date,
              advance_date date, advance_notes text, payout_description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row public."XenditPayouts"%rowtype;
  v_mine boolean;
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_row from public."XenditPayouts" x
   where x."PayoutID" = p_payout_id and x."Kind" in ('Salary', 'Advance');
  if not found then
    raise exception 'Receipt not found.';
  end if;

  v_mine := v_row."Username" = p_username;
  if not ((v_mine and not v_row."IsTest") or public.is_payroll_authorized(p_username, p_password)) then
    raise exception 'Receipt not found.';
  end if;

  if v_mine and not v_row."IsTest" and v_row."Status" = 'SUCCEEDED' and v_row."EmployeeSeenAtUtc" is null then
    update public."XenditPayouts" set "EmployeeSeenAtUtc" = now() where "PayoutID" = v_row."PayoutID";
  end if;

  return query
    -- Every column cast to the declared type (some source columns are varchar / timestamp without tz).
    select x."PayoutID"::uuid, x."ReferenceID"::text, x."Kind"::text, x."Status"::text, x."IsTest"::boolean, v_mine,
           x."Username"::text, coalesce(x."DisplayName"::text, su."DisplayName"::text, x."Username"::text), x."Amount"::numeric,
           coalesce(x."ChannelName"::text, x."ChannelCode"::text), x."AccountName"::text,
           ('••' || right(x."AccountNumber"::text, 4))::text, x."XenditPayoutID"::text, coalesce(x."FailureCode"::text, x."Error"::text),
           coalesce(sb."DisplayName"::text, x."SentBy"::text), x."CreatedAtUtc"::timestamptz, x."PaidAtUtc"::timestamptz,
           x."LineID"::uuid, r."PayCycle"::text, r."PeriodStart"::date, r."PeriodEnd"::date, r."PayDate"::date,
           a."AdvanceDate"::date, a."Notes"::text,
           -- The description sent with the payout, as Xendit echoed it back (e.g. "Cash advance Nov 12 2026 RS Pet
           -- Stop") - Xendit recommends it on the receipt; some banks / e-wallets show it to the recipient too.
           (x."LastResponse" ->> 'description')::text
    from public."XenditPayouts" x
    left join public."StaffUsers" su on su."Username" = x."Username"
    left join public."StaffUsers" sb on sb."Username" = x."SentBy"
    left join public."PayrollRuns" r on r."RunID" = x."RunID"
    left join public."PayrollCashAdvances" a on a."AdvanceID" = x."AdvanceID"
    where x."PayoutID" = v_row."PayoutID";
end;
$$;

grant execute on function public.my_get_payout_receipt(text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- The caller's own paid (live) salary / advance payouts. p_unseen_only = the portal notice: not opened or
-- dismissed yet, paid in the last 14 days.

drop function if exists public.my_list_payout_receipts(text, text, boolean);

create or replace function public.my_list_payout_receipts(p_username text, p_password text, p_unseen_only boolean default false)
returns table(payout_id uuid, kind text, amount numeric, paid_at timestamptz, channel_name text, account_masked text,
              line_id uuid, pay_cycle text, period_start date, period_end date, advance_date date, seen boolean)
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select x."PayoutID"::uuid, x."Kind"::text, x."Amount"::numeric, x."PaidAtUtc"::timestamptz,
           coalesce(x."ChannelName"::text, x."ChannelCode"::text),
           ('••' || right(x."AccountNumber"::text, 4))::text, x."LineID"::uuid, r."PayCycle"::text,
           r."PeriodStart"::date, r."PeriodEnd"::date, a."AdvanceDate"::date, x."EmployeeSeenAtUtc" is not null
    from public."XenditPayouts" x
    left join public."PayrollRuns" r on r."RunID" = x."RunID"
    left join public."PayrollCashAdvances" a on a."AdvanceID" = x."AdvanceID"
    where x."Username" = p_username and x."Kind" in ('Salary', 'Advance')
      and not x."IsTest" and x."Status" = 'SUCCEEDED'
      and (not coalesce(p_unseen_only, false)
           or (x."EmployeeSeenAtUtc" is null and x."PaidAtUtc" > now() - interval '14 days'))
    order by x."PaidAtUtc" desc nulls last
    limit 200;
end;
$$;

grant execute on function public.my_list_payout_receipts(text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Dismiss the portal notice for some (or, with null, all) of the caller's own payouts.

drop function if exists public.my_dismiss_payout_notices(text, text, uuid[]);

create or replace function public.my_dismiss_payout_notices(p_username text, p_password text, p_payout_ids uuid[])
returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_count integer;
begin
  if not public.is_staff_authorized(p_username, p_password) then
    raise exception 'Not authorized.';
  end if;

  update public."XenditPayouts"
     set "EmployeeSeenAtUtc" = now()
   where "Username" = p_username and "Kind" in ('Salary', 'Advance') and "EmployeeSeenAtUtc" is null
     and (p_payout_ids is null or "PayoutID" = any(p_payout_ids));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.my_dismiss_payout_notices(text, text, uuid[]) to anon;

notify pgrst, 'reload schema';

-- Check - one result.
select 'seen column' as section,
       case when exists (select 1 from information_schema.columns where table_name = 'XenditPayouts' and column_name = 'EmployeeSeenAtUtc')
            then 'ready' else 'MISSING' end as value
union all
select 'receipt functions',
       case when to_regprocedure('public.my_get_payout_receipt(text, text, uuid)') is not null
             and to_regprocedure('public.my_list_payout_receipts(text, text, boolean)') is not null
             and to_regprocedure('public.my_dismiss_payout_notices(text, text, uuid[])') is not null
            then 'ready' else 'MISSING' end
union all
select 'paid salary / advance payouts (live)',
       count(*)::text from public."XenditPayouts" where "Kind" in ('Salary', 'Advance') and not "IsTest" and "Status" = 'SUCCEEDED'
union all
select 'notices that will show now',
       count(*)::text from public."XenditPayouts"
        where "Kind" in ('Salary', 'Advance') and not "IsTest" and "Status" = 'SUCCEEDED'
          and "EmployeeSeenAtUtc" is null and "PaidAtUtc" > now() - interval '14 days';
