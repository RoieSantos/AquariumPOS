-- Diagnostic for "Could not find the function public.staff_set_purchase_order_line_cost ... in
-- the schema cache" (and any sibling error from supabase_item_cost_and_po_line_cost.sql).
--
-- That PostgREST error has exactly two causes, and they need different fixes:
--   A. The function genuinely does not exist - the migration was never run, or it aborted partway
--      and everything after the failure point is missing.
--   B. The function exists but PostgREST is still serving a stale schema cache, so it refuses to
--      route to it.
--
-- Section 1 tells you which of the two it is. Section 2 fixes B.
--
-- Note the portal's UI degrades SILENTLY when the migration is missing: an absent unit_cost comes
-- back undefined, which renders as an empty Unit Cost box and a "-" Line Cost - exactly what a
-- genuinely uncosted line looks like. So "the Cost column appeared" is NOT evidence the migration
-- ran; only this script is.

-- ---------------------------------------------------------------------------
-- 1. What actually landed?
-- ---------------------------------------------------------------------------

-- Expect 10 rows, all with exists_now = true. Any row saying false is the point to investigate:
-- the objects are created in this order in the migration, so the FIRST false is usually where it
-- aborted, and everything below it will be false too.
select
  expected.ordinality as run_order,
  expected.name,
  (
    select count(*) > 0
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = expected.name
  ) as exists_now
from unnest(array[
  'admin_set_item_cost',
  'admin_bulk_set_item_costs',
  'staff_search_items',
  'staff_create_purchase_order',
  'staff_add_purchase_order_line',
  'staff_set_purchase_order_line_cost',
  'staff_list_purchase_order_lines',
  'staff_list_posted_purchase_order_lines',
  'staff_post_purchase_order',
  'admin_get_purchase_summary'
]) with ordinality as expected(name, ordinality)
order by expected.ordinality;

-- The two new columns. Both must be present - if these are missing, the migration failed at the
-- very first statement and nothing else in it ran.
select
  t.table_name,
  (
    select count(*) > 0
    from information_schema.columns c
    where c.table_schema = 'public'
      and c.table_name = t.table_name
      and c.column_name = 'UnitCost'
  ) as has_unitcost_column
from (values ('PurchaseOrderLines'), ('PostedPurchaseOrderLines')) as t(table_name);

-- Argument lists of the functions the error mentions. staff_set_purchase_order_line_cost must
-- read exactly: p_admin_username text, p_admin_password text, p_entry_no bigint, p_unit_cost
-- numeric. A DIFFERENT argument list here (rather than a missing row) means an older overload is
-- still resolving and PostgREST cannot match the call.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'staff_set_purchase_order_line_cost',
    'staff_add_purchase_order_line',
    'staff_list_purchase_order_lines',
    'staff_search_items'
  )
order by p.proname, arguments;

-- Execute grants. A function that exists but was never granted to anon is invisible to the portal
-- and produces a permissions error rather than this one - checked here so the two don't get
-- confused. Expect one row per function with has_anon_execute = true.
select
  p.proname,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'admin_set_item_cost',
    'admin_bulk_set_item_costs',
    'staff_set_purchase_order_line_cost',
    'admin_get_purchase_summary'
  )
order by p.proname;

-- ---------------------------------------------------------------------------
-- 2. Fix for cause B (function exists, cache is stale)
-- ---------------------------------------------------------------------------

-- Run this if section 1 shows the function DOES exist and is granted to anon. PostgREST caches
-- the schema and only re-reads it on this notification; without it a newly created function stays
-- unroutable until the API restarts on its own.
notify pgrst, 'reload schema';

-- If section 1 shows the function does NOT exist, this notify changes nothing - re-run
-- supabase_item_cost_and_po_line_cost.sql instead and watch for the first error it reports. The
-- whole migration is safe to re-run: every statement is "create or replace", "add column if not
-- exists", or a guarded drop.
