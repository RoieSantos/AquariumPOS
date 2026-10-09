-- Advance Orders tab: "Could not choose the best candidate function between admin_list_advance_orders(...)".
--
-- Two versions of admin_list_advance_orders exist side by side: the current one from
-- supabase_online_orders_list_sort.sql (+ p_sort_column / p_sort_dir) and the older 7-argument one that
-- came back when supabase_advance_order_production.sql (or supabase_advance_orders_custom_flags.sql) was
-- re-run after it. All the extra parameters have defaults, so a call without sort args matches both.
--
-- Drops only the old 7-argument version; the sort version (same body, plus sorting) stays.
-- Run AFTER supabase_online_orders_list_sort.sql. Safe to re-run.

drop function if exists public.admin_list_advance_orders(text, text, text, text, int, int, text);

notify pgrst, 'reload schema';

-- Verification - expect ONE row, ending in "p_sort_column text, p_sort_dir text".
select 'function' as section, p.proname::text as item, pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_list_advance_orders';
