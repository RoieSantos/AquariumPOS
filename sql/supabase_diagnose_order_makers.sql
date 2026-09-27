-- Read-only check for "the Assign popup on Online Orders shows no names". Run each block in the
-- Supabase SQL editor and read the results top to bottom. Changes nothing.

-- 1. Do the functions/column the popup needs exist? Every row should say true.
--    false on any of these = that SQL file hasn't been run yet:
--      has_staff_roles_column / has_set_roles_fn -> supabase_staff_users_staff_roles.sql
--      has_order_makers_fn                       -> supabase_online_order_maker_by_role.sql
--      has_dispatcher_column                     -> supabase_online_order_dispatcher.sql
--      verify_login_returns_roles                -> supabase_production_manager_role.sql
select
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'StaffUsers' and column_name = 'StaffRoles') as has_staff_roles_column,
  exists (select 1 from pg_proc where proname = 'admin_set_staff_user_roles') as has_set_roles_fn,
  exists (select 1 from pg_proc where proname = 'staff_list_order_makers') as has_order_makers_fn,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'OnlineOrders' and column_name = 'AssignedDispatcher') as has_dispatcher_column,
  exists (select 1 from pg_proc where proname = 'verify_login' and pg_get_function_result(oid) like '%staff_roles%') as verify_login_returns_roles;

-- 2. Who has which role? (Only runs once the StaffRoles column exists - step 1's first column.)
--    Anyone meant to show in the popup needs IsActive = true and the role in StaffRoles.
select "Username", "DisplayName", "IsActive", "StaffRoles"
from public."StaffUsers"
where cardinality("StaffRoles") > 0
order by "IsActive" desc, "Username";

-- 3. Exactly what the popup receives (the same filter staff_list_order_makers uses).
select "Username", coalesce(nullif(trim("DisplayName"), ''), "Username") as display_name, "StaffRoles"
from public."StaffUsers"
where "IsActive" and "StaffRoles" && array['TankMaker', 'StandMaker', 'Dispatcher']::text[]
order by 2;
