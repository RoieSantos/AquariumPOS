-- Lets the Timesheets page show "this run will need ~PxK Cash / ~PyK Digital, you currently have
-- PaK / PbK on hand" BEFORE the officer creates the run - so they know how much to prepare, not
-- just find out at Finalize time (admin_get_payroll_run_funding_requirement, supabase_payroll_
-- funding_ledger.sql, already does this but only for a run that already exists).
--
-- Deliberately reuses admin_create_payroll_run itself instead of re-implementing its math (Hourly
-- vs Semi-Monthly-fixed vs Weekly-blended-across-months, overtime, undertime, Paid Rest Day, Cash
-- Advance sweep-in - see supabase_payroll_semimonthly_fixed_pay.sql) - hand-porting that logic a
-- second time is exactly the kind of duplicate-calculator drift this project has already been
-- burned by elsewhere (the AI bot's separate aquarium pricing copy). Instead this runs the real
-- function inside a nested block, reads the NetPay it produced, then deliberately raises to force
-- Postgres to roll back everything that block did (the run, its lines/items, and the Cash Advance
-- Status='Applied' sweep) - so nothing is actually created. A real error from admin_create_payroll_
-- run (e.g. no timesheet entries yet) is re-raised as-is so the officer sees the same message they'd
-- get from actually trying to create the run.
--
-- Run this AFTER supabase_payroll_semimonthly_fixed_pay.sql.

create or replace function public.admin_get_projected_payroll_run_requirement(
  p_admin_username text,
  p_admin_password text,
  p_pay_cycle text,
  p_period_start date,
  p_period_end date,
  p_pay_date date default null
)
returns table(cash_required numeric, digital_required numeric, cash_balance numeric, digital_balance numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_run_id uuid;
  v_cash_required numeric := 0;
  v_digital_required numeric := 0;
begin
  if not public.is_payroll_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_period_start is null or p_period_end is null or p_period_end < p_period_start then
    raise exception 'A valid period start/end is required.';
  end if;

  begin
    v_run_id := public.admin_create_payroll_run(
      p_admin_username, p_admin_password, p_pay_cycle, p_period_start, p_period_end,
      coalesce(p_pay_date, p_period_end)
    );

    select coalesce(sum(l."NetPay") filter (where coalesce(su."PaymentMethod", 'Cash') = 'Cash'), 0),
           coalesce(sum(l."NetPay") filter (where coalesce(su."PaymentMethod", 'Cash') = 'Digital'), 0)
      into v_cash_required, v_digital_required
      from public."PayrollRunLines" l
      join public."StaffUsers" su on su."Username" = l."Username"
      where l."RunID" = v_run_id;

    -- Force a rollback of everything admin_create_payroll_run just did - this projection must never
    -- actually create a run or touch Cash Advance statuses.
    raise exception using message = '__PROJECTION_DISCARD__';
  exception when others then
    if sqlerrm <> '__PROJECTION_DISCARD__' then
      raise;
    end if;
  end;

  return query select v_cash_required, v_digital_required, public.payroll_fund_balance('Cash'), public.payroll_fund_balance('Digital');
end;
$$;

grant execute on function public.admin_get_projected_payroll_run_requirement(text, text, text, date, date, date) to anon;
