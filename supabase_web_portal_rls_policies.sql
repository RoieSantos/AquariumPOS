-- Row Level Security (RLS) "policies" for the AquariumPOS Web Portal.
--
-- *** SECURITY NOTE ***
-- The portal uses a fully custom username/password login (see
-- supabase_staff_users_table.sql) instead of Supabase Auth. Because that
-- login is UI-only (no real session/JWT), Postgres has no way to tell a
-- "logged in" browser apart from any other request using the public anon
-- key. To keep the app working, these policies grant full access to the
-- "anon" role - i.e. RLS is effectively OPEN here. The tables below are
-- protected only by how well you keep the anon key from being (ab)used,
-- NOT by the portal's login screen. The AquariumPOS desktop app is
-- unaffected either way: it uses the Supabase SECRET/service-role key,
-- which always bypasses RLS.
--
-- Run this in the Supabase SQL Editor AFTER running:
--   - supabase_item_serial_tracking.sql (if not already run)
--   - supabase_month_end.sql (if not already run)
--   - supabase_expense_report_tables.sql (if not already run)
--   - supabase_customer_aquarium_tables.sql
--   - supabase_staff_users_table.sql
--   - (Transfer_Header / Transfer_Line already exist from earlier Transfer Order work)

-- Transfer Orders
alter table public."Transfer_Header" enable row level security;
drop policy if exists "Authenticated full access" on public."Transfer_Header";
drop policy if exists "Anon full access" on public."Transfer_Header";
create policy "Anon full access" on public."Transfer_Header"
    for all to anon, authenticated using (true) with check (true);

alter table public."Transfer_Line" enable row level security;
drop policy if exists "Authenticated full access" on public."Transfer_Line";
drop policy if exists "Anon full access" on public."Transfer_Line";
create policy "Anon full access" on public."Transfer_Line"
    for all to anon, authenticated using (true) with check (true);

-- Reports: Month End
alter table public."MonthEndHeader" enable row level security;
drop policy if exists "Authenticated full access" on public."MonthEndHeader";
drop policy if exists "Anon full access" on public."MonthEndHeader";
create policy "Anon full access" on public."MonthEndHeader"
    for all to anon, authenticated using (true) with check (true);

alter table public."MonthEndLines" enable row level security;
drop policy if exists "Authenticated full access" on public."MonthEndLines";
drop policy if exists "Anon full access" on public."MonthEndLines";
create policy "Anon full access" on public."MonthEndLines"
    for all to anon, authenticated using (true) with check (true);

-- Reports: Expense Report
alter table public."ExpenseReportHeader" enable row level security;
drop policy if exists "Authenticated full access" on public."ExpenseReportHeader";
drop policy if exists "Anon full access" on public."ExpenseReportHeader";
create policy "Anon full access" on public."ExpenseReportHeader"
    for all to anon, authenticated using (true) with check (true);

alter table public."ExpenseReportLines" enable row level security;
drop policy if exists "Authenticated full access" on public."ExpenseReportLines";
drop policy if exists "Anon full access" on public."ExpenseReportLines";
create policy "Anon full access" on public."ExpenseReportLines"
    for all to anon, authenticated using (true) with check (true);

-- Serial Tracker
alter table public."ItemSerialTracking" enable row level security;
drop policy if exists "Authenticated full access" on public."ItemSerialTracking";
drop policy if exists "Anon full access" on public."ItemSerialTracking";
create policy "Anon full access" on public."ItemSerialTracking"
    for all to anon, authenticated using (true) with check (true);

-- Customer Aquarium
alter table public."CompleteAquariumSetHeader" enable row level security;
drop policy if exists "Authenticated full access" on public."CompleteAquariumSetHeader";
drop policy if exists "Anon full access" on public."CompleteAquariumSetHeader";
create policy "Anon full access" on public."CompleteAquariumSetHeader"
    for all to anon, authenticated using (true) with check (true);

alter table public."CompleteAquariumSetLine" enable row level security;
drop policy if exists "Authenticated full access" on public."CompleteAquariumSetLine";
drop policy if exists "Anon full access" on public."CompleteAquariumSetLine";
create policy "Anon full access" on public."CompleteAquariumSetLine"
    for all to anon, authenticated using (true) with check (true);

-- NOTE: public."StaffUsers" is NOT included here on purpose - it has RLS
-- enabled with zero policies (see supabase_staff_users_table.sql), so it
-- stays fully blocked from direct API access regardless of role.
