-- =============================================================================
-- ONE-OFF: add new employee Matt P. Heraldez (independent contractor).
--
-- Same shape as the Payroll Setup "+ New Employee" form / admin_create_payroll_employee and the
-- Excel roster import (supabase_import_employees_from_excel.sql): plain StaffUsers row, no role
-- flags, temporary password '123456' with MustChangePassword = true.
--
-- Pay: Weekly cycle, MonthlySalary 15000 (stored as the monthly figure, same as the other Weekly
-- helpers at 15000 - a weekly run pays 15000 * 12 / 52 = 3,461.54). Payment Method: Cash.
-- Hire Date: 2026-11-01 (Sunday).
--
-- Employee No. = the highest existing Employee No. + 1, keeping its format: the trailing digits
-- are incremented and any prefix / zero-padding is kept (e.g. 'EMP-014' -> 'EMP-015', '27' -> '28').
-- If no employee has a number yet, it starts at '1'.
--
-- Not filled in (contract left it blank): Phone No. - set later in Payroll Setup.
--
-- Safe to re-run: if Matt already exists it only fills in Hire Date / Payment Method, and assigns
-- an Employee No. only if he doesn't have one yet (never renumbers him).
-- Ends with one result row showing the employee.
-- =============================================================================

do $$
declare
  v_username text;
  v_last_no  text;
  v_next_no  text;
begin
  -- Highest existing Employee No. (by its trailing number), excluding Matt himself.
  select su."EmployeeNo"
    into v_last_no
  from public."StaffUsers" su
  where su."EmployeeNo" ~ '[0-9]+$'
    and su."Username" <> 'matt'
  order by (substring(su."EmployeeNo" from '([0-9]+)$'))::bigint desc
  limit 1;

  if v_last_no is null then
    v_next_no := '1';
  else
    v_next_no := substring(v_last_no from '^(.*?)[0-9]+$')
              || lpad(((substring(v_last_no from '([0-9]+)$'))::bigint + 1)::text,
                      length(substring(v_last_no from '([0-9]+)$')), '0');
  end if;

  select "Username" into v_username
  from public."StaffUsers"
  where "Username" = 'matt'
     or lower(trim("DisplayName")) in ('matt p. heraldez', 'matt heraldez')
  limit 1;

  if v_username is null then
    insert into public."StaffUsers" (
      "Username", "PasswordHash", "DisplayName", "MustChangePassword",
      "SuperUser", "SalesUser", "SerialAdmin", "DeliveryTeam", "OnlineOrderStaff", "ProductionMember", "PayrollOfficer",
      "Position", "Birthdate", "HomeAddress", "HireDate",
      "PayCycle", "PayType", "MonthlySalary", "PaymentMethod", "EmployeeNo"
    )
    values (
      'matt', public.hash_password('123456'), 'Matt P. Heraldez', true,
      false, false, false, false, false, false, false,
      'Independent Contractor', '2007-11-28'::date, 'Amaya Residences Phase 1, B2 Lot 21, Amaya IV', '2026-11-01'::date,
      'Weekly', 'Salary', 15000, 'Cash', v_next_no
    );
    raise notice 'CREATED: matt (Employee No. %, last was %)', v_next_no, coalesce(v_last_no, 'none');
  else
    update public."StaffUsers"
       set "HireDate"      = '2026-11-01'::date,
           "PaymentMethod" = 'Cash',
           "EmployeeNo"    = coalesce(nullif(trim("EmployeeNo"), ''), v_next_no)
     where "Username" = v_username;
    raise notice 'UPDATED existing employee %', v_username;
  end if;
end $$;

select "Username", "DisplayName", "EmployeeNo", "Position", "HireDate", "Birthdate", "HomeAddress",
       "PayCycle", "PayType", "MonthlySalary", "PaymentMethod", "MustChangePassword", "IsActive"
from public."StaffUsers"
where "Username" = 'matt'
   or lower(trim("DisplayName")) in ('matt p. heraldez', 'matt heraldez');
