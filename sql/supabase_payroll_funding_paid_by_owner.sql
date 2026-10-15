-- Payroll Funding "Funded By" - per "sometimes i use my own money too for paying the salary".
--
-- The payroll officer already logs every cash / GCash amount they receive for payroll as a Funding
-- entry (Payroll Setup > Funding, PayrollLedgerEntries EntryType 'Funding'). This adds who the money
-- came from:
--   Business       - business money, as before (nothing else happens).
--   Owner Capital  - the owner's own money, kept in the business -> also an Owner Funds "Capital In"
--   Owner Loan     - the owner's own money, to be paid back       -> also an Owner Funds "Owner Loan"
-- The Owner Funds entry uses the same Cash / Digital method (Dr Cash or Digital, Cr 3000 Owner's
-- Equity / 2100 Due to Owner), so business cash goes up by what the owner put in, and payroll then
-- pays from it. The salaries themselves stay a business expense (they're still in payroll), which
-- is how the Dashboard's My View counts them; the owner's part shows under "Owner Put In".
--
-- Owner options need a super user (is_admin_authorized) - a payroll officer can only log Business.
-- The journal shows the entry's Label as "Funding (Owner Capital)" / "Funding (Owner Loan)".
-- Funding entries have no delete, so nothing to keep in sync; voiding the Owner Funds entry on the
-- Owner Funds page leaves the payroll float as is (it just stops counting as owner money).
--
-- Run AFTER supabase_payroll_ledger_funding_merge.sql and supabase_owner_funds.sql. Safe to re-run.

alter table public."PayrollLedgerEntries" add column if not exists "FundedBy" varchar(20);
alter table public."PayrollLedgerEntries" add column if not exists "OwnerFundEntryID" uuid;

drop function if exists public.admin_add_payroll_funding_entry(text, text, text, numeric, text);
drop function if exists public.admin_add_payroll_funding_entry(text, text, text, numeric, text, text);

create or replace function public.admin_add_payroll_funding_entry(
  p_admin_username text,
  p_admin_password text,
  p_method text,
  p_amount numeric,
  p_notes text default null,
  p_funded_by text default 'Business'
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_funded_by text := coalesce(nullif(trim(coalesce(p_funded_by, '')), ''), 'Business');
  v_today date := (now() at time zone 'Asia/Manila')::date;
  v_ledger_id uuid;
  v_owner_entry uuid;
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

  if v_funded_by not in ('Business', 'Owner Capital', 'Owner Loan') then
    return query select false, ('Invalid Funded By: ' || v_funded_by)::text;
    return;
  end if;

  if v_funded_by <> 'Business' and not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Only a super user can log funding from the owner''s own money.'::text;
    return;
  end if;

  insert into public."PayrollLedgerEntries"
    ("PeriodStart", "PeriodEnd", "PayDate", "EntryType", "Label", "Notes", "Amount", "Method", "FundedBy", "PostedBy")
  values (timezone('utc', now())::date, timezone('utc', now())::date, timezone('utc', now())::date,
          'Funding',
          case when v_funded_by = 'Business' then 'Funding' else 'Funding (' || v_funded_by || ')' end,
          nullif(trim(p_notes), ''), p_amount, p_method, v_funded_by, p_admin_username)
  returning "LedgerID" into v_ledger_id;

  if v_funded_by <> 'Business' then
    v_owner_entry := public._owner_fund_add(
      case v_funded_by when 'Owner Loan' then 'Owner Loan' else 'Capital In' end,
      v_today, p_amount, p_method,
      'Payroll funding' || coalesce(' - ' || nullif(trim(coalesce(p_notes, '')), ''), ''),
      null, null, null, null, null, p_admin_username);
    update public."PayrollLedgerEntries" set "OwnerFundEntryID" = v_owner_entry where "LedgerID" = v_ledger_id;
  end if;

  return query select true,
    (case when v_funded_by = 'Business' then 'Funding entry logged.'
          else 'Funding entry logged, and added to Owner Funds as ' || case v_funded_by when 'Owner Loan' then 'an Owner Loan.' else 'Capital In.' end
     end)::text;
end;
$$;

grant execute on function public.admin_add_payroll_funding_entry(text, text, text, numeric, text, text) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: the new 6-argument admin_add_payroll_funding_entry and the two columns.
select 'function' as section, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_add_payroll_funding_entry'
union all
select 'column', column_name::text
from information_schema.columns
where table_schema = 'public' and table_name = 'PayrollLedgerEntries' and column_name in ('FundedBy', 'OwnerFundEntryID');
