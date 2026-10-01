-- Timesheets: a saved Digital cash advance shows as "Cash" in the weekly grid - per "once saved the
-- cash advance is always defaulting to cash even though its digital".
--
-- The save (admin_upsert_cash_advances_bulk) stores Method correctly; the grid re-reads it from
-- admin_list_cash_advances and falls back to 'Cash' when the result has no "method" field. The
-- original supabase_payroll_cash_advances.sql drops/recreates admin_list_cash_advances WITHOUT
-- method/employee_no, so re-running it after supabase_payroll_cash_advance_method_employee_no.sql
-- silently removes the column. This puts the method-aware version back (same as that file's).
--
-- Step 2 lists the latest advances so you can see what Method is actually stored - an advance that
-- was unlocked and re-saved while the grid showed "Cash" was saved back as Cash and needs fixing
-- by hand (update "PayrollCashAdvances" / "PayrollLedgerEntries" by AdvanceID / SourceAdvanceID).

-- ---------------------------------------------------------------------------
-- 1. admin_list_cash_advances with method + employee_no
drop function if exists public.admin_list_cash_advances(text, text, text, text, date, date, int, int);

create or replace function public.admin_list_cash_advances(
  p_admin_username text,
  p_admin_password text,
  p_username text default null,
  p_status text default null,
  p_date_start date default null,
  p_date_end date default null,
  p_page int default 1,
  p_page_size int default 50
)
returns table(
  advance_id uuid,
  username text,
  display_name text,
  employee_no text,
  advance_date date,
  amount numeric,
  method text,
  notes text,
  status text,
  applied_to_run_id uuid,
  applied_at_utc timestamptz,
  created_by text,
  created_at_utc timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select a."AdvanceID", a."Username"::text, su."DisplayName"::text, su."EmployeeNo"::text, a."AdvanceDate", a."Amount", a."Method"::text, a."Notes"::text,
           a."Status"::text, a."AppliedToRunID", a."AppliedAtUtc", a."CreatedBy"::text, a."CreatedAtUtc",
           count(*) over()
    from public."PayrollCashAdvances" a
    join public."StaffUsers" su on su."Username" = a."Username"
    where (p_username is null or a."Username" = p_username)
      and (p_status is null or a."Status" = p_status)
      and (p_date_start is null or a."AdvanceDate" >= p_date_start)
      and (p_date_end is null or a."AdvanceDate" <= p_date_end)
    order by a."AdvanceDate" desc, a."CreatedAtUtc" desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_cash_advances(text, text, text, text, date, date, int, int) to anon;

-- ---------------------------------------------------------------------------
-- 2. Check: what Method is actually stored on the latest advances.
select a."AdvanceID", a."Username", a."AdvanceDate", a."Amount", a."Method", a."Status", l."Method" as "LedgerMethod"
from public."PayrollCashAdvances" a
left join public."PayrollLedgerEntries" l on l."SourceAdvanceID" = a."AdvanceID"
order by a."CreatedAtUtc" desc
limit 30;
