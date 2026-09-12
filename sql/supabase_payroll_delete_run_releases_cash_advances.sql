-- Deleting a Draft payroll run was failing with a foreign key violation
-- ("PayrollCashAdvances_AppliedToRunID_fkey") whenever a Cash Advance had been auto-applied to
-- that run (supabase_payroll_cash_advances.sql's admin_create_payroll_run pulls in every
-- Outstanding advance and marks it Applied/AppliedToRunID). The advance itself should NOT be
-- deleted along with the run - it just goes back to being an Outstanding advance so it's picked
-- up again by the next run created for that employee, same as if it had never been applied.
--
-- Run this AFTER supabase_payroll_cash_advances.sql and supabase_payroll_officer_access.sql.

create or replace function public.admin_delete_payroll_run(p_admin_username text, p_admin_password text, p_run_id uuid)
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

  select "Status" into v_status from public."PayrollRuns" where "RunID" = p_run_id;

  if v_status is null then
    return query select false, 'Payroll run not found.'::text;
    return;
  end if;
  if v_status = 'Finalized' then
    return query select false, 'A finalized payroll run cannot be deleted.'::text;
    return;
  end if;

  -- Revert any Cash Advance this run had auto-applied back to Outstanding instead of letting it
  -- block the delete (FK on AppliedToRunID) or cascading its deletion - the advance was actually
  -- released to the employee and stays on record; it's simply unapplied again.
  update public."PayrollCashAdvances"
    set "Status" = 'Outstanding', "AppliedToRunID" = null, "AppliedToLineID" = null, "AppliedAtUtc" = null
    where "AppliedToRunID" = p_run_id;

  delete from public."PayrollRuns" where "RunID" = p_run_id;

  return query select true, 'Payroll run deleted.'::text;
end;
$$;

grant execute on function public.admin_delete_payroll_run(text, text, uuid) to anon;
