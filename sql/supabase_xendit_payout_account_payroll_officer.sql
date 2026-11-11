-- Payroll officers can set up employees' Xendit salary payout accounts - per "can you give my payroll officer access
-- to the payroll setup where she can setup the xendit account for each of employee".
--
--   - Payroll Setup > Edit > Salary Payout (Xendit): payroll officers can now see and save it, not just super users
--     (admin_get_payroll_payout_account / admin_set_payroll_payout_account use is_payroll_authorized, which also
--     lets super users in).
--   - Sending money is unchanged: only a super user can Pay via Xendit / Approve & Send.
--   - Safeguards, because a changed account number redirects someone's pay:
--       1. When a payroll officer (not a super user) changes an account, a Telegram alert goes to the usual chat:
--          who changed whose account, from what to what (numbers masked to the last 4).
--       2. A payroll officer can't save an account number that is already another employee's payout account (e.g.
--          their own) - a super user has to do that.
--   - "Last changed by" in the form already shows who changed it last (PayoutUpdatedBy).
--
-- Run AFTER supabase_xendit_payroll_payouts.sql (replaces both functions; same parameters and results).
-- Safe to re-run. Needs js/payrollSetup.js ?v=payoutofficer1. Ends with ONE result.

create or replace function public.admin_get_payroll_payout_account(p_admin_username text, p_admin_password text, p_username text)
returns table(pay_via_xendit boolean, channel_code text, channel_name text, account_number text, account_name text,
              updated_by text, updated_at timestamptz)
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
    select su."PayViaXendit", su."PayoutChannelCode", su."PayoutChannelName", su."PayoutAccountNumber", su."PayoutAccountName",
           su."PayoutUpdatedBy", su."PayoutUpdatedAtUtc"
    from public."StaffUsers" su where su."Username" = p_username;
end;
$$;

grant execute on function public.admin_get_payroll_payout_account(text, text, text) to anon;

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
  v_is_super boolean;
  v_old record;
  v_new_via boolean;
  v_new_channel text;
  v_other text;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Only a payroll officer or a super user can change payout accounts.'::text;
    return;
  end if;
  v_is_super := public.is_admin_authorized(p_admin_username, p_admin_password);

  select su."DisplayName", su."PayViaXendit", su."PayoutChannelCode", su."PayoutChannelName", su."PayoutAccountNumber", su."PayoutAccountName"
    into v_old
    from public."StaffUsers" su where su."Username" = p_username
    for update;
  if not found then
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
         "PayoutUpdatedBy" = p_admin_username,
         "PayoutUpdatedAtUtc" = now()
   where "Username" = p_username;

  -- Safeguard 1: tell the super users when a payroll officer changes where someone is paid.
  if not v_is_super and (
       v_old."PayoutChannelCode" is distinct from v_code
       or v_old."PayoutAccountNumber" is distinct from v_number
       or v_old."PayoutAccountName" is distinct from v_name
       or coalesce(v_old."PayViaXendit", false) is distinct from v_new_via) then
    perform public._telegram_send_message(
      'Payroll: ' || p_admin_username || ' changed the salary payout account of ' || coalesce(v_old."DisplayName", p_username) || E'.\n'
      || 'Was: ' || case when v_old."PayoutChannelCode" is null then 'none'
                         else coalesce(v_old."PayoutChannelName", v_old."PayoutChannelCode") || ' ••' || right(coalesce(v_old."PayoutAccountNumber", ''), 4)
                              || ' (' || coalesce(v_old."PayoutAccountName", '') || ')' || case when v_old."PayViaXendit" then ', pay via Xendit ON' else '' end end || E'\n'
      || 'Now: ' || case when v_code is null then 'none'
                         else coalesce(v_new_channel, v_code) || ' ••' || right(v_number, 4) || ' (' || v_name || ')'
                              || case when v_new_via then ', pay via Xendit ON' else '' end end || E'\n'
      || 'Check it in Payroll Setup before the next Xendit payout.');
  end if;

  return query select true, case when v_code is null then 'Payout account removed.' else 'Payout account saved.' end::text;
end;
$$;

grant execute on function public.admin_set_payroll_payout_account(text, text, text, boolean, text, text, text, text) to anon;

notify pgrst, 'reload schema';

-- Check - one result.
select 'get' as section,
       case when pg_get_functiondef('public.admin_get_payroll_payout_account(text, text, text)'::regprocedure) like '%is_payroll_authorized%'
            then 'payroll officers can view' else 'OLD' end as value
union all
select 'set', case when pg_get_functiondef('public.admin_set_payroll_payout_account(text, text, text, boolean, text, text, text, text)'::regprocedure) like '%is_payroll_authorized%'
                   then 'payroll officers can save (with Telegram alert)' else 'OLD' end
union all
select 'telegram', case when exists (select 1 from public."PortalSettings" where "SettingKey" = 'TELEGRAM_CHAT_ID' and coalesce(trim("SettingValue"), '') <> '')
                        then 'alerts will be sent' else 'no TELEGRAM_CHAT_ID - alerts are skipped' end;
