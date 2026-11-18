-- Payroll Setup > Settings > "Xendit Payout Proof": the records email CC'd on every Xendit payout proof
-- (PortalSettings 'XENDIT_PAYOUT_RECEIPT_CC', read by _payout_receipt_emails when a payout is sent).
--
--   - Same people as the employee Receipt Email (payroll officers + super users). It receives EVERY employee's
--     proof, so a payroll officer's change is sent to the super users on Telegram, like a payout account change.
--   - One address, or several split by commas. Blank = no records copy.
--   - Only payouts sent after a change use the new address (each payout keeps the email it was first sent with).
--
-- Run AFTER supabase_xendit_payout_receipt_email.sql. Safe to re-run. Needs js/payrollSetup.js ?v=receiptcc1.
-- Ends with ONE result.

create or replace function public.admin_get_payout_receipt_cc(p_admin_username text, p_admin_password text)
returns table(email_cc text, updated_by text, updated_at timestamptz)
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
    select ps."SettingValue"::text, ps."UpdatedBy"::text, ps."UpdatedAtUtc"::timestamptz
    from public."PortalSettings" ps where ps."SettingKey" = 'XENDIT_PAYOUT_RECEIPT_CC';
end;
$$;

grant execute on function public.admin_get_payout_receipt_cc(text, text) to anon;

create or replace function public.admin_set_payout_receipt_cc(p_admin_username text, p_admin_password text, p_email_cc text)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_is_super boolean;
  v_old text;
  v_new text;
  v_addr text;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  v_is_super := public.is_admin_authorized(p_admin_username, p_admin_password);

  -- Tidy: split on commas / semicolons / spaces, lower-case, drop blanks and repeats, re-join with ", ".
  select string_agg(distinct a, ', ') into v_new
    from (select lower(trim(x)) as a from regexp_split_to_table(coalesce(p_email_cc, ''), '[,;\s]+') as x) t
   where a <> '';
  if v_new is not null then
    foreach v_addr in array string_to_array(v_new, ', ') loop
      if v_addr !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
        return query select false, ('Not an email address: ' || v_addr)::text;
        return;
      end if;
    end loop;
    if length(v_new) > 500 then
      return query select false, 'Too many addresses (500 characters at most).'::text;
      return;
    end if;
  end if;

  select nullif(trim(ps."SettingValue"), '') into v_old from public."PortalSettings" ps where ps."SettingKey" = 'XENDIT_PAYOUT_RECEIPT_CC';

  insert into public."PortalSettings" ("SettingKey", "SettingValue", "Description", "IsPublicToStaff", "UpdatedBy", "UpdatedAtUtc")
  values ('XENDIT_PAYOUT_RECEIPT_CC', coalesce(v_new, ''),
          'Records email CC''d on every Xendit payout proof. Set from Payroll Setup > Settings > Xendit Payout Proof.',
          false, p_admin_username, now())
  on conflict ("SettingKey") do update
     set "SettingValue" = excluded."SettingValue", "Description" = excluded."Description",
         "UpdatedBy" = excluded."UpdatedBy", "UpdatedAtUtc" = excluded."UpdatedAtUtc";

  if not v_is_super and v_old is distinct from v_new then
    perform public._telegram_send_message(
      'Payroll: ' || p_admin_username || E' changed the records email that gets every Xendit payout proof.\n'
      || 'Was: ' || coalesce(v_old, 'none') || E'\n'
      || 'Now: ' || coalesce(v_new, 'none') || E'\n'
      || 'Check it in Payroll Setup > Settings before the next Xendit payout.');
  end if;

  return query select true, case when v_new is null then 'Records copy turned off.' else 'Saved.' end::text;
end;
$$;

grant execute on function public.admin_set_payout_receipt_cc(text, text, text) to anon;

notify pgrst, 'reload schema';

-- Check - one result.
select 'read' as section,
       case when to_regprocedure('public.admin_get_payout_receipt_cc(text, text)') is not null then 'ready' else 'MISSING' end as value
union all
select 'save',
       case when to_regprocedure('public.admin_set_payout_receipt_cc(text, text, text)') is not null then 'ready' else 'MISSING' end
union all
select 'needs receipt email SQL first',
       case when to_regprocedure('public._payout_receipt_emails(uuid[])') is not null then 'ok' else 'RUN supabase_xendit_payout_receipt_email.sql' end
union all
select 'records CC now',
       coalesce((select nullif(trim("SettingValue"), '') from public."PortalSettings" where "SettingKey" = 'XENDIT_PAYOUT_RECEIPT_CC'), 'not set');
