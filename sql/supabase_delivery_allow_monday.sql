-- Delivery calendar: allow Mondays - per "can you allow now schedule in calendar even if monday".
--
-- Mondays were blocked ("Mondays are not available for delivery.") in:
--   admin_create_delivery_stop        (Assign to Date - live def supabase_delivery_assign_automated_order_search.sql)
--   admin_move_delivery_stop          (Move Date - live def supabase_delivery_stop_route_tagging.sql)
--   admin_assign_delivery_date_vendor (per-date vendor tag - supabase_delivery_date_vendors.sql)
-- Rather than copying those whole functions here (and risking an older body overwriting a newer one),
-- this reads each LIVE definition from the database, removes only the Monday check, and re-creates it -
-- everything else in the function stays exactly as it is now. Grants are kept (same signature).
--
-- NOT changed (still no Monday):
--   * public_schedule_online_order_delivery - the AI bot's customer self-scheduling
--     (supabase_chatbot_delivery_scheduling_rpc.sql); the bot still tells customers Mondays aren't available.
--   * admin_upsert_delivery_route_schedule - the weekly fixed route in Delivery Setup (Monday row stays
--     "No Delivery").
--
-- If supabase_delivery_assign_automated_order_search.sql, supabase_delivery_stop_route_tagging.sql or
-- supabase_delivery_date_vendors.sql is ever re-run, the Monday block comes back - run this again after.
-- Safe to re-run (a function with no Monday check left is skipped). Ends with a check: still_blocks_monday
-- should be false on every row. Needs js/delivery.js ?v=monday1.

do $$
declare
  r record;
  v_def text;
  v_new text;
begin
  for r in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_create_delivery_stop', 'admin_move_delivery_stop', 'admin_assign_delivery_date_vendor')
  loop
    v_def := pg_get_functiondef(r.oid);
    -- Both shapes: "raise exception '...';" and "return query select false, '...'::text; return;"
    v_new := regexp_replace(
      v_def,
      'if\s+extract\s*\(\s*dow\s+from\s+p_\w+\s*\)\s*=\s*1\s+then\s+(raise\s+exception|return\s+query\s+select\s+false\s*,)\s*''Mondays are not available for delivery\.''(::text)?\s*;(\s*return\s*;)?\s*end\s+if\s*;',
      '-- Mondays allowed (supabase_delivery_allow_monday.sql)',
      'gi');
    if v_new <> v_def then
      execute v_new;
      raise notice 'Removed the Monday block from % (oid %).', r.proname, r.oid;
    else
      raise notice 'No Monday block found in % (oid %) - left as is.', r.proname, r.oid;
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';

-- Check: false = Mondays now allowed.
select p.proname::text as function_name,
       pg_get_function_identity_arguments(p.oid) as arguments,
       (p.prosrc ilike '%Mondays are not available%') as still_blocks_monday
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_create_delivery_stop', 'admin_move_delivery_stop', 'admin_assign_delivery_date_vendor',
                    'public_schedule_online_order_delivery')
order by 1, 2;
