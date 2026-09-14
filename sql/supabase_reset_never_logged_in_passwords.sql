-- One-off password reset, per "can you make the password 123456 and force them to change the
-- password on their next sign in" - scoped to exactly the "Never logged in" group from
-- supabase_employees_without_access_report.sql's second query: active, payroll-enrolled
-- employees who have never actually signed into the portal (LastLoginAtUtc is null). Does NOT
-- touch deactivated accounts or anyone who has already logged in at least once, per explicit
-- scope choice.
--
-- Uses the existing hash_password() helper (supabase_staff_users_table.sql) so this matches
-- every other password write in the app (bcrypt via pgcrypto's crypt()/gen_salt('bf', 10)) -
-- never store a plain password in "PasswordHash" directly.
--
-- Sets MustChangePassword = true so js/auth.js's requireAuth() forces change-password.html on
-- their very next login (see supabase_staff_users_table.sql's comment on that flag) - they will
-- NOT be able to use 123456 for anything beyond that first sign-in.
--
-- The RETURNING clause prints exactly which accounts were changed and their new password, right
-- in the Supabase SQL Editor's results grid, after you run this - that doubles as the "share me
-- all the username and password" list (the password is the same, 123456, for every row here).
-- Run this in the Supabase SQL Editor.

update public."StaffUsers"
set "PasswordHash" = public.hash_password('123456'),
    "MustChangePassword" = true,
    "FailedAttempts" = 0,
    "LockedUntilUtc" = null
where "PayCycle" is not null
  and "IsActive" is true
  and "LastLoginAtUtc" is null
returning
  "EmployeeNo",
  "Username",
  "DisplayName",
  '123456'::text as "TemporaryPassword",
  "MustChangePassword";
