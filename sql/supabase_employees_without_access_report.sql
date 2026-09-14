-- Ad-hoc report (not a migration - nothing to "run" as a schema change, just a SELECT) for
-- "can you share me all employee that dont have access yet" - i.e. which payroll-enrolled
-- employees can't currently use the portal (and therefore can't see My Payslips yet). Paste
-- either query below into the Supabase SQL Editor and run it.

-- ---------------------------------------------------------------------------
-- 1. Deactivated accounts: enrolled in payroll, but their login is switched off (IsActive =
-- false) - they physically cannot log in at all until a Super User reactivates them in User
-- Setup / Payroll Setup.
select
  "EmployeeNo",
  "Username",
  "DisplayName",
  "PayCycle",
  "PayType",
  "IsActive"
from public."StaffUsers"
where "PayCycle" is not null   -- enrolled in payroll at all
  and "IsActive" is not true
order by "DisplayName";

-- ---------------------------------------------------------------------------
-- 2. Never logged in: active accounts that have never actually signed into the portal yet
-- (LastLoginAtUtc is null) - these employees technically CAN log in, they just haven't yet, so
-- they may not have seen the My Payslips announcement or don't know their credentials work.
select
  "EmployeeNo",
  "Username",
  "DisplayName",
  "PayCycle",
  "PayType",
  "LastLoginAtUtc"
from public."StaffUsers"
where "PayCycle" is not null
  and "IsActive" is true
  and "LastLoginAtUtc" is null
order by "DisplayName";
