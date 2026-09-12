-- Adds pagination and a free-text search / Entry Type filter to the Payroll Ledger report,
-- same pattern as Item Setup's search box + admin_list_* p_page/p_page_size/total_count
-- convention (see docs/js/itemSetup.js, docs/js/pagination.js) - "filter same as we can filter
-- from BC" (Business Central-style list filtering).
--
-- p_page is left nullable and defaulting to null on purpose: payroll-run.html's per-run ledger
-- section (js/payrollRun.js) calls this RPC with only p_run_id set and expects every row back
-- (that section has no pagination bar) - passing p_page null skips LIMIT/OFFSET entirely so that
-- caller is unaffected. payroll-ledger.html (js/payrollLedger.js) is the only caller that passes
-- p_page/p_page_size.
--
-- Run this AFTER supabase_payroll_ledger_method.sql.

drop function if exists public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date);

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
  p_page_size int default 50
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
           "PeriodStart", "PeriodEnd", "PayDate", "EntryType"::text, "Label"::text, "Amount", "Method"::text,
           "SourceAdvanceID", "PostedBy"::text, "PostedAtUtc",
           count(*) over (),
           sum(case when "EntryType" = 'NetPay' then "Amount" else 0 end) over ()
    from public."PayrollLedgerEntries"
    where (p_run_id is null or "RunID" = p_run_id)
      and (p_username is null or "Username" = p_username)
      and (p_period_start is null or "PeriodEnd" >= p_period_start)
      and (p_period_end is null or "PeriodStart" <= p_period_end)
      and (p_entry_type is null or "EntryType" = p_entry_type)
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

grant execute on function public.admin_list_payroll_ledger_entries(text, text, uuid, text, date, date, text, text, int, int) to anon;
