-- ============================================================================
-- READ THIS BEFORE RUNNING
-- ============================================================================
-- supabase_orders_sync_tables.sql intentionally locked these 4 tables down:
--
--   revoke all on public."OnlineOrders" from anon, authenticated;
--   revoke all on public."OnlineOrderLines" from anon, authenticated;
--   revoke all on public."AdvanceOrders" from anon, authenticated;
--   revoke all on public."AdvanceOrderLines" from anon, authenticated;
--
-- ...specifically so the publishable (anon) key could never read/write order
-- data directly - only through the admin_list_online_orders / admin_list_
-- advance_orders SECURITY DEFINER functions, which check a username/password
-- before returning anything.
--
-- This script REVERSES that lockdown for these 4 tables: it grants anon
-- direct SELECT/INSERT/UPDATE, plus a permissive row-level-security policy
-- (the tables have RLS enabled with no policies, so a GRANT alone still
-- wouldn't let any rows through). After running this, anyone holding the
-- publishable key - which is not a secret; it's embedded in the desktop app
-- and would be embedded in any public web client too - can read or modify
-- ANY row in these 4 tables directly, with no login check.
--
-- WHY THIS IS NEEDED RIGHT NOW: the desktop app's Supabase "secret" key
-- (GlobalSettings.TransferHeaderSupabaseAuthorization in OnlinefunctionsEvents/
-- GlobalSettings.cs) is being rejected by Supabase as "Unregistered API key" -
-- confirmed by calling the REST API directly with that exact key. Because that
-- key never authenticates, every sync call from the desktop silently falls
-- back to running as anon, which is why it's hitting this lockdown.
--
-- THE SECURE FIX (recommended over running this script): get the current
-- valid secret key from Supabase Dashboard -> Project Settings -> API Keys
-- and update GlobalSettings.cs with it. A working secret key bypasses RLS
-- entirely for the desktop app's own calls, without reopening anon access to
-- everyone else. Only run this script if you've decided that trade-off is
-- acceptable (e.g. as a temporary stop-gap), understanding it applies to
-- every anon-key holder, not just the desktop app.
--
-- NOTE ALSO: this same broken secret key affects every other Supabase push
-- from the desktop app (Warehouses, Items, Transfers, MonthEnd, Expense
-- Reports, etc.) - those tables were never locked down the way these 4 were,
-- so they've been silently running as anon successfully as long as anon had
-- grants on them. This script only covers the 4 order tables that were
-- explicitly locked down.
-- ============================================================================

grant select, insert, update on public."OnlineOrders" to anon;
grant select, insert, update on public."OnlineOrderLines" to anon;
grant select, insert, update on public."AdvanceOrders" to anon;
grant select, insert, update on public."AdvanceOrderLines" to anon;

drop policy if exists "allow_anon_desktop_sync" on public."OnlineOrders";
create policy "allow_anon_desktop_sync" on public."OnlineOrders"
  for all to anon using (true) with check (true);

drop policy if exists "allow_anon_desktop_sync" on public."OnlineOrderLines";
create policy "allow_anon_desktop_sync" on public."OnlineOrderLines"
  for all to anon using (true) with check (true);

drop policy if exists "allow_anon_desktop_sync" on public."AdvanceOrders";
create policy "allow_anon_desktop_sync" on public."AdvanceOrders"
  for all to anon using (true) with check (true);

drop policy if exists "allow_anon_desktop_sync" on public."AdvanceOrderLines";
create policy "allow_anon_desktop_sync" on public."AdvanceOrderLines"
  for all to anon using (true) with check (true);
