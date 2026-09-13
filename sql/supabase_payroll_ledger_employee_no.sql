-- Surfaces Employee No. on the Payroll Ledger report, joined read-only from StaffUsers (same
-- "flow the employee no. from the employee setup" pattern already used on the Cash Advances
-- journal) - per "can we add employee no. on the payroll ledger so it can easily track." Null for
-- Funding/Payroll rows (not tied to one employee) same as Employee is already blank there.
--
-- Run this AFTER supabase_payroll_ledger_funding_merge.sql.

drop function if exists public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date, text, text, int, int, text, boolean);

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
  employee_no text,
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
    select le."LedgerID", le."RunID", le."LineID", le."Username"::text, le."DisplayName"::text, su."EmployeeNo"::text, le."PayCycle"::text,
           le."PeriodStart", le."PeriodEnd", le."PayDate", le."EntryType"::text, le."Label"::text, le."Notes"::text, le."Amount", le."Method"::text,
           le."SourceAdvanceID", le."PostedBy"::text, le."PostedAtUtc",
           count(*) over (),
           sum(case when le."EntryType" = 'NetPay' then le."Amount" else 0 end) over ()
    from public."PayrollLedgerEntries" le
    left join public."StaffUsers" su on su."Username" = le."Username"
    where (p_run_id is null or le."RunID" = p_run_id)
      and (p_username is null or le."Username" = p_username)
      and (p_period_start is null or le."PeriodEnd" >= p_period_start)
      and (p_period_end is null or le."PeriodStart" <= p_period_end)
      and (p_entry_type is null or le."EntryType" = p_entry_type)
      and (p_method is null or le."Method" = p_method)
      and (not p_funding_only or le."Method" is not null)
      and (
        p_search is null or trim(p_search) = '' or
        le."Label" ilike '%' || trim(p_search) || '%' or
        le."DisplayName" ilike '%' || trim(p_search) || '%' or
        le."Username" ilike '%' || trim(p_search) || '%'
      )
    order by le."PeriodStart" desc nulls last, le."PostedAtUtc" desc, le."DisplayName",
      case le."EntryType" when 'CashAdvance' then 0 when 'BasePay' then 1 when 'Addition' then 2 when 'Deduction' then 3 else 4 end
    limit case when p_page is null then null else greatest(coalesce(p_page_size, 50), 1) end
    offset case when p_page is null then 0 else (greatest(p_page, 1) - 1) * greatest(coalesce(p_page_size, 50), 1) end;
end;
$$;

grant execute on function public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date, text, text, int, int, text, boolean) to anon;
