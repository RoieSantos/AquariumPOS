# AquariumPOS Web Portal

A lightweight, staff-only web portal for AquariumPOS - plain HTML/CSS/JS, no build step. It talks directly to the same Supabase project the desktop app syncs to.

## Modules

- **Transfer Orders** - view existing transfer requests and create new ones (writes to `Transfer_Header` / `Transfer_Line`, the same tables the desktop app already pulls from via `SyncTransferRequestsFromSupabaseToLocalDb`, so new web-created transfer orders will show up in the desktop app too).
- **Reports** - read-only Month End and Expense Report viewers (`MonthEndHeader`/`MonthEndLines`, `ExpenseReportHeader`/`ExpenseReportLines`).
- **Customer Aquarium** - create/edit "complete aquarium set" packages (`CompleteAquariumSetHeader`/`CompleteAquariumSetLine`). These are **new Supabase-only tables** - the desktop app does not currently push its local packages here, so the portal starts empty.
- **Custom Calculator** - embeds the `WebAquariumCalculator` calculator (copied under `docs/` so GitHub Pages serves it too). Its Light/Pump Item dropdowns query the real `Items` catalog (`staff_list_items_by_category`, same `CategoryCode` lookup - `LIGHTS` / `PUMP` - the desktop app's Complete Aquarium Set builder uses) instead of a free-typed price, so it now requires being opened from within the portal (reads the logged-in session from `sessionStorage`) rather than as a fully standalone page.
- **Serial Tracker** - search/filter `ItemSerialTracking` and update Status/Location.
- **User Setup** - lets **super user** staff create new portal logins (username, password, display name, assigned warehouse). Only visible/usable to accounts with `"SuperUser" = true`.

## One-time Supabase setup (do this before using the portal)

Run these SQL scripts in the **Supabase SQL Editor** (Postgres dialect), in this order, if not already run:

1. `supabase_item_serial_tracking.sql`
2. `supabase_month_end.sql` (+ `supabase_month_end_add_opening_stock.sql` if needed)
3. `supabase_expense_report_tables.sql`
4. `supabase_customer_aquarium_tables.sql` (new)
5. `supabase_staff_users_table.sql` (new - custom login table + `verify_login()` function)
6. `supabase_web_portal_rls_policies.sql` (new/updated - see security note below)

Then create a login for each staff member by running this in the SQL Editor (replace the values):

```sql
insert into public."StaffUsers" ("Username", "PasswordHash", "DisplayName", "WarehouseName", "SuperUser")
values ('jane', public.hash_password('ChangeMe123!'), 'Jane Doe', 'Main Warehouse', true)
on conflict ("Username") do update set "PasswordHash" = excluded."PasswordHash", "WarehouseName" = excluded."WarehouseName", "SuperUser" = excluded."SuperUser";
```

- `WarehouseName` should match the `"From Warehouse"`/`"To Warehouse"` text used in `Transfer_Header` exactly - the portal uses it to filter the Transfer Orders list to that user's own warehouse. Leave it blank for staff who should see every warehouse.
- `SuperUser = true` unlocks the **User Setup** page for that account, so at least one account needs this set manually via SQL the first time (afterwards, super users can create more logins - including other super users - from the portal itself).

## ⚠️ Security note: custom login instead of Supabase Auth

This portal uses a **custom username/password table** (`StaffUsers`) instead of Supabase Auth, per project decision. Because this is a static site with no backend server, that login can only gate the portal's **UI** - it is not a real session/JWT that Row Level Security can check. As a result:

- `supabase_web_portal_rls_policies.sql` grants full read/write access on Transfer Orders, Reports, Customer Aquarium, and Serial Tracker tables to the **anon** role (the same public key embedded in this portal's JavaScript).
- Anyone who extracts that anon key (trivial via browser dev tools) can read/write that data directly through the Supabase API, bypassing the login screen entirely.
- The `StaffUsers` table itself stays locked down (RLS with no policies) - only the `verify_login()` function can check credentials, and it never exposes password hashes.

If you ever want the data itself to be genuinely protected (not just the UI), the underlying mechanism would need to switch to real Supabase Auth sessions or a signed-token backend (e.g. a Supabase Edge Function) - ask if you'd like that added later.

## Running the portal

This is a static site - no build, no npm install. Just open `index.html` in a browser, or serve the `docs` folder with any static file server (e.g. `npx serve`, IIS, GitHub Pages, etc.). It must be served over `http://` or `https://` (not `file://`) for the Supabase JS client to work reliably.

## Security notes

- `js/config.js` only contains the Supabase **publishable/anon key** - safe for client-side use.
- The desktop app's **secret/service-role key** must never be added to any file in this folder.
- Passwords in `StaffUsers` are hashed with bcrypt (`pgcrypto`) and checked entirely server-side via `verify_login()` - the hash is never sent to the browser. Logins lock for 15 minutes after 5 failed attempts.
- See the "Security note" section above - RLS on the portal's data tables is open to the anon role because the custom login has no real session to check.
