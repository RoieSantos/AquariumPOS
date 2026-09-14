-- Ad-hoc report (not a migration - just a SELECT) for "can you share me all employees that is
-- required to login" - read as "Require password change at next login" ticked
-- (StaffUsers."MustChangePassword" = true, User Setup's checkbox of that exact name), i.e. every
-- account that will be forced to change-password.html on its next sign-in. Now also filtered to
-- IsActive = true per follow-up ("also filter isactive = true") - a deactivated account can't log
-- in at all regardless of this flag, so it wouldn't belong on this list anyway.

-- 1. Full detail (one row per employee) - run this if you still want to see the other columns.
select
  "EmployeeNo",
  "Username",
  "DisplayName",
  "IsActive",
  "LastLoginAtUtc"
from public."StaffUsers"
where "MustChangePassword" is true
  and "IsActive" is true
order by "DisplayName";

-- 2. Usernames only, one per row - easiest to select-all and copy straight out of the results
-- grid as a plain list.
select "Username"
from public."StaffUsers"
where "MustChangePassword" is true
  and "IsActive" is true
order by "Username";

-- 3. Usernames only, as ONE cell of newline-separated text ("export to text") - copy this single
-- cell's value and it pastes as a ready-made plain-text list (e.g. into a chat message or a script).
select string_agg("Username", chr(10) order by "Username") as usernames_text
from public."StaffUsers"
where "MustChangePassword" is true
  and "IsActive" is true;
