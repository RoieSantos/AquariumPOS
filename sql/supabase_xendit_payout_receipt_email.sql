-- Xendit emails a transaction proof for each salary / cash advance payout - per Xendit support (ticket 2805101):
-- "the recipient's email address should be specified within the receipt_notification object ... email_to ...
-- email_cc ... email_bcc" and "once a payout has been completed, the transaction proof cannot be resent".
--
--   - Payroll Setup > Edit > Salary Payout (Xendit): new "Receipt Email" (StaffUsers.PayoutEmail). Same people as
--     the account itself (payroll officers + super users); a payroll officer's change is in the Telegram alert too.
--   - The xendit-payroll-payout Edge Function asks _payout_receipt_emails before sending; each NEW payout then
--     carries receipt_notification { email_to: [employee email], email_cc: [records email] }. Xendit emails the
--     proof (beneficiary, bank, account number, bank reference, description) when it's sent - in test mode too.
--   - Optional records copy: PortalSettings 'XENDIT_PAYOUT_RECEIPT_CC' (one address, or several split by commas)
--     is CC'd on every proof - and gets it alone (as "to") for an employee with no email. Set it at the bottom.
--   - XenditPayouts.ReceiptEmailTo / ReceiptEmailCc record where each payout's proof went (the payout receipt page
--     shows it). Payouts already sent can't get a proof - Xendit can't resend.
--   - Old Payroll Setup pages keep working: p_email left out = email unchanged.
--
-- Run AFTER supabase_xendit_payout_account_payroll_officer.sql (replaces admin_get_payroll_payout_account and
-- admin_set_payroll_payout_account) and supabase_xendit_payout_receipts.sql (replaces my_get_payout_receipt).
-- Safe to re-run. Needs js/payrollSetup.js ?v=receiptemail1, js/payoutReceipt.js ?v=5 and the redeployed
-- xendit-payroll-payout Edge Function. Ends with ONE result.

alter table public."StaffUsers" add column if not exists "PayoutEmail" text;
alter table public."XenditPayouts" add column if not exists "ReceiptEmailTo" text;
alter table public."XenditPayouts" add column if not exists "ReceiptEmailCc" text;

-- ---------------------------------------------------------------------------
-- Payroll Setup: read (now with the email).

drop function if exists public.admin_get_payroll_payout_account(text, text, text);

create or replace function public.admin_get_payroll_payout_account(p_admin_username text, p_admin_password text, p_username text)
returns table(pay_via_xendit boolean, channel_code text, channel_name text, account_number text, account_name text,
              updated_by text, updated_at timestamptz, email text)
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
    select su."PayViaXendit"::boolean, su."PayoutChannelCode"::text, su."PayoutChannelName"::text, su."PayoutAccountNumber"::text,
           su."PayoutAccountName"::text, su."PayoutUpdatedBy"::text, su."PayoutUpdatedAtUtc"::timestamptz, su."PayoutEmail"::text
    from public."StaffUsers" su where su."Username" = p_username;
end;
$$;

grant execute on function public.admin_get_payroll_payout_account(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Payroll Setup: save. Same as supabase_xendit_payout_account_payroll_officer.sql plus p_email
-- (null = leave as is, '' = remove).

drop function if exists public.admin_set_payroll_payout_account(text, text, text, boolean, text, text, text, text);

create or replace function public.admin_set_payroll_payout_account(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_pay_via_xendit boolean,
  p_channel_code text,
  p_channel_name text,
  p_account_number text,
  p_account_name text,
  p_email text default null
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
  v_is_super boolean;
  v_old record;
  v_new_via boolean;
  v_new_channel text;
  v_other text;
  v_email text;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Only a payroll officer or a super user can change payout accounts.'::text;
    return;
  end if;
  v_is_super := public.is_admin_authorized(p_admin_username, p_admin_password);

  select su."DisplayName", su."PayViaXendit", su."PayoutChannelCode", su."PayoutChannelName", su."PayoutAccountNumber",
         su."PayoutAccountName", su."PayoutEmail"
    into v_old
    from public."StaffUsers" su where su."Username" = p_username
    for update;
  if not found then
    return query select false, 'Employee not found.'::text;
    return;
  end if;

  -- Receipt email: null = unchanged (older Payroll Setup page), blank = removed.
  if p_email is null then
    v_email := v_old."PayoutEmail";
  else
    v_email := nullif(lower(trim(p_email)), '');
    if v_email is not null and (v_email !~ '^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$' or length(v_email) > 200) then
      return query select false, 'Enter one valid receipt email, e.g. juan@gmail.com.'::text;
      return;
    end if;
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

    -- Safeguard 2: a payroll officer can't point one employee's pay at another employee's account.
    if not v_is_super then
      select coalesce(su."DisplayName", su."Username") into v_other
        from public."StaffUsers" su
       where su."Username" <> p_username and su."PayoutChannelCode" = v_code and su."PayoutAccountNumber" = v_number
       limit 1;
      if v_other is not null then
        return query select false, ('That account is already ' || v_other || '''s payout account. Ask a super user if it really should be shared.')::text;
        return;
      end if;
    end if;
  end if;

  v_new_via := coalesce(p_pay_via_xendit, false) and v_code is not null;
  v_new_channel := case when v_code is null then null else nullif(left(trim(coalesce(p_channel_name, '')), 120), '') end;

  update public."StaffUsers"
     set "PayViaXendit" = v_new_via,
         "PayoutChannelCode" = v_code,
         "PayoutChannelName" = v_new_channel,
         "PayoutAccountNumber" = v_number,
         "PayoutAccountName" = v_name,
         "PayoutEmail" = v_email,
         "PayoutUpdatedBy" = p_admin_username,
         "PayoutUpdatedAtUtc" = now()
   where "Username" = p_username;

  -- Safeguard 1: tell the super users when a payroll officer changes where someone is paid (or where the proof goes).
  if not v_is_super and (
       v_old."PayoutChannelCode" is distinct from v_code
       or v_old."PayoutAccountNumber" is distinct from v_number
       or v_old."PayoutAccountName" is distinct from v_name
       or coalesce(v_old."PayViaXendit", false) is distinct from v_new_via
       or v_old."PayoutEmail" is distinct from v_email) then
    perform public._telegram_send_message(
      'Payroll: ' || p_admin_username || ' changed the salary payout account of ' || coalesce(v_old."DisplayName", p_username) || E'.\n'
      || 'Was: ' || case when v_old."PayoutChannelCode" is null then 'none'
                         else coalesce(v_old."PayoutChannelName", v_old."PayoutChannelCode") || ' ••' || right(coalesce(v_old."PayoutAccountNumber", ''), 4)
                              || ' (' || coalesce(v_old."PayoutAccountName", '') || ')' || case when v_old."PayViaXendit" then ', pay via Xendit ON' else '' end end
      || case when v_old."PayoutEmail" is distinct from v_email then ', receipt email ' || coalesce(v_old."PayoutEmail", 'none') else '' end || E'\n'
      || 'Now: ' || case when v_code is null then 'none'
                         else coalesce(v_new_channel, v_code) || ' ••' || right(v_number, 4) || ' (' || v_name || ')'
                              || case when v_new_via then ', pay via Xendit ON' else '' end end
      || case when v_old."PayoutEmail" is distinct from v_email then ', receipt email ' || coalesce(v_email, 'none') else '' end || E'\n'
      || 'Check it in Payroll Setup before the next Xendit payout.');
  end if;

  return query select true, case when v_code is null then 'Payout account removed.' else 'Payout account saved.' end::text;
end;
$$;

grant execute on function public.admin_set_payroll_payout_account(text, text, text, boolean, text, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Edge Function helper: where each payout's Xendit proof goes. Stamps it on the payout the first time (a re-send
-- with the same Idempotency-key keeps the first answer anyway). Salary / advance payouts only.

create or replace function public._payout_receipt_emails(p_payout_ids uuid[])
returns table(payout_id uuid, email_to text, email_cc text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_cc text;
begin
  select nullif(trim(ps."SettingValue"), '') into v_cc
    from public."PortalSettings" ps where ps."SettingKey" = 'XENDIT_PAYOUT_RECEIPT_CC';

  update public."XenditPayouts" x
     set "ReceiptEmailTo" = coalesce(su."PayoutEmail", v_cc),
         "ReceiptEmailCc" = case when su."PayoutEmail" is null then null else v_cc end
    from public."StaffUsers" su
   where x."PayoutID" = any(coalesce(p_payout_ids, '{}')) and x."Kind" in ('Salary', 'Advance')
     and su."Username" = x."Username" and x."ReceiptEmailTo" is null and x."XenditPayoutID" is null;

  return query
    select x."PayoutID"::uuid, x."ReceiptEmailTo"::text, x."ReceiptEmailCc"::text
    from public."XenditPayouts" x
    where x."PayoutID" = any(coalesce(p_payout_ids, '{}')) and x."ReceiptEmailTo" is not null;
end;
$$;

revoke all on function public._payout_receipt_emails(uuid[]) from public, anon, authenticated;
grant execute on function public._payout_receipt_emails(uuid[]) to service_role;

-- ---------------------------------------------------------------------------
-- Payout receipt page: same as supabase_xendit_payout_receipts.sql plus where Xendit emailed the proof.

drop function if exists public.my_get_payout_receipt(text, text, uuid);

create or replace function public.my_get_payout_receipt(p_username text, p_password text, p_payout_id uuid)
returns table(payout_id uuid, reference_id text, kind text, status text, is_test boolean, is_mine boolean,
              username text, display_name text, amount numeric, channel_name text, account_name text,
              account_masked text, xendit_payout_id text, failure text, sent_by text, sent_at timestamptz,
              paid_at timestamptz, line_id uuid, pay_cycle text, period_start date, period_end date, pay_date date,
              advance_date date, advance_notes text, payout_description text, receipt_email_to text)
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
    select x."PayoutID"::uuid, x."ReferenceID"::text, x."Kind"::text, x."Status"::text, x."IsTest"::boolean, v_mine,
           x."Username"::text, coalesce(x."DisplayName"::text, su."DisplayName"::text, x."Username"::text), x."Amount"::numeric,
           coalesce(x."ChannelName"::text, x."ChannelCode"::text), x."AccountName"::text,
           ('••' || right(x."AccountNumber"::text, 4))::text, x."XenditPayoutID"::text, coalesce(x."FailureCode"::text, x."Error"::text),
           coalesce(sb."DisplayName"::text, x."SentBy"::text), x."CreatedAtUtc"::timestamptz, x."PaidAtUtc"::timestamptz,
           x."LineID"::uuid, r."PayCycle"::text, r."PeriodStart"::date, r."PeriodEnd"::date, r."PayDate"::date,
           a."AdvanceDate"::date, a."Notes"::text,
           (x."LastResponse" ->> 'description')::text,
           -- The employee's own address only (not the records CC).
           case when x."ReceiptEmailTo" is not null and x."ReceiptEmailTo" = su."PayoutEmail" then x."ReceiptEmailTo"::text end
    from public."XenditPayouts" x
    left join public."StaffUsers" su on su."Username" = x."Username"
    left join public."StaffUsers" sb on sb."Username" = x."SentBy"
    left join public."PayrollRuns" r on r."RunID" = x."RunID"
    left join public."PayrollCashAdvances" a on a."AdvanceID" = x."AdvanceID"
    where x."PayoutID" = v_row."PayoutID";
end;
$$;

grant execute on function public.my_get_payout_receipt(text, text, uuid) to anon;

notify pgrst, 'reload schema';

-- Optional - a copy of every proof to your records email (replace the address, then run just these two lines):
-- insert into public."PortalSettings" ("SettingKey", "SettingValue") values ('XENDIT_PAYOUT_RECEIPT_CC', 'records@example.com')
--   on conflict ("SettingKey") do update set "SettingValue" = excluded."SettingValue";

-- Check - one result.
select 'email column' as section,
       case when exists (select 1 from information_schema.columns where table_name = 'StaffUsers' and column_name = 'PayoutEmail')
            then 'ready' else 'MISSING' end as value
union all
select 'payroll setup save',
       case when to_regprocedure('public.admin_set_payroll_payout_account(text, text, text, boolean, text, text, text, text, text)') is not null
             and to_regprocedure('public.admin_set_payroll_payout_account(text, text, text, boolean, text, text, text, text)') is null
            then 'takes the receipt email' else 'OLD' end
union all
select 'edge function helper',
       case when to_regprocedure('public._payout_receipt_emails(uuid[])') is not null then 'ready' else 'MISSING' end
union all
select 'employees with a receipt email', count(*)::text from public."StaffUsers" where "PayoutEmail" is not null
union all
select 'records CC (XENDIT_PAYOUT_RECEIPT_CC)',
       coalesce((select nullif(trim("SettingValue"), '') from public."PortalSettings" where "SettingKey" = 'XENDIT_PAYOUT_RECEIPT_CC'), 'not set (optional)');
