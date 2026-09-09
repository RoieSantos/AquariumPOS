-- Lets Payroll Setup toggle StaffUsers."IsActive" directly, per "in the payroll profile can you
-- add boolean there inactive . so the system will know that the employee is inactive already".
--
-- Deliberately NOT a new column: StaffUsers."IsActive" already exists (User Setup's "Active"
-- checkbox) and admin_create_payroll_run (supabase_payroll_tables.sql) already filters new runs to
-- WHERE "IsActive" IS TRUE - marking someone inactive already excludes them from future payroll
-- runs. The only real gap was that Payroll Setup showed this as a read-only badge with no way to
-- change it, forcing a trip to User Setup for something that's arguably a payroll-officer decision
-- too. This just adds that same column as an editable field here - a second "Inactive" boolean
-- would just duplicate IsActive and create an ambiguous "which one wins" situation.
--
-- Run this AFTER supabase_payroll_tables.sql.

drop function if exists public.admin_update_payroll_profile(text, text, text, text, numeric);

create or replace function public.admin_update_payroll_profile(
  p_admin_username text,
  p_admin_password text,
  p_username text,
  p_pay_cycle text,
  p_monthly_salary numeric,
  p_is_active boolean default true
)
returns table(success boolean, message text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    return query select false, 'Not authorized.'::text;
    return;
  end if;

  if p_pay_cycle is not null and p_pay_cycle not in ('SemiMonthly', 'Weekly') then
    return query select false, 'Pay cycle must be Semi-Monthly or Weekly.'::text;
    return;
  end if;

  if not exists (select 1 from public."StaffUsers" where "Username" = p_username) then
    return query select false, 'That staff login no longer exists.'::text;
    return;
  end if;

  update public."StaffUsers"
    set "PayCycle" = p_pay_cycle,
        "MonthlySalary" = coalesce(p_monthly_salary, 0),
        "IsActive" = coalesce(p_is_active, true)
    where "Username" = p_username;

  return query select true, 'Payroll profile updated.'::text;
end;
$$;

grant execute on function public.admin_update_payroll_profile(text, text, text, text, numeric, boolean) to anon;
