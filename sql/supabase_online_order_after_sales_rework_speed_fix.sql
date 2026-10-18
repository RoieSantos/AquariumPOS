-- URGENT speed fix: makers' My Assignments shows "canceling statement due to statement timeout" since
-- supabase_online_order_after_sales_rework.sql.
--
-- Why: that file's My Assignments branch called _online_order_my_rework_reopened() (a function that calls
-- another function twice) for EVERY Shipped / Delivered order the maker was ever assigned - hundreds of
-- orders x several tiny queries each. Fine in the SQL editor (long timeout), too slow for the website's
-- short one.
--
-- Fix: the same rule written inline - a cheap status test first, then one indexed EXISTS on the (small)
-- rework table - no function calls per row. Same result: the order is on the maker's list while a part of
-- theirs is sent back and not marked done again.
--
-- Patches the LIVE admin_list_online_orders (every overload) in that one spot only. Run AFTER
-- supabase_online_order_after_sales_rework.sql. Safe to re-run (already-fixed functions are skipped).
-- Ends with a check: inline_fixed should be true and still_slow false on every row.

do $$
declare
  r record;
  v_def text;
  v_new text;
begin
  for r in
    select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'admin_list_online_orders'
  loop
    v_def := pg_get_functiondef(r.oid);
    if v_def not ilike '%_online_order_my_rework_reopened(o."OrderID"%' then
      raise notice 'admin_list_online_orders (oid %) has no slow after-sales call - left as is.', r.oid;
      continue;
    end if;
    v_new := regexp_replace(
      v_def,
      'public\._online_order_my_rework_reopened\(\s*o\."OrderID"\s*,\s*p_admin_username\s*\)',
      E'lower(trim(coalesce(o."Status", \'\'))) in (\'shipped\', \'delivered\', \'2\', \'received\', \'3\')\n'
        || E'              and exists (select 1 from public."OnlineOrderProductionRework" ar\n'
        || E'                          where ar."OrderID" = o."OrderID"\n'
        || E'                            and ((ar."Role" = \'tank\' and o."AssignedTankMaker" = p_admin_username)\n'
        || E'                              or (ar."Role" = \'stand\' and o."AssignedStandMaker" = p_admin_username))\n'
        || E'                            and not exists (select 1 from public."OnlineOrderProductionDone" ad\n'
        || E'                                            where ad."OrderID" = ar."OrderID" and ad."Role" = ar."Role"\n'
        || E'                                              and ad."DoneAtUtc" > ar."SentBackAtUtc"))',
      'gi');
    execute v_new;
    raise notice 'admin_list_online_orders (oid %): after-sales rework check made inline.', r.oid;
  end loop;
end;
$$;

notify pgrst, 'reload schema';

select p.oid, pg_get_function_identity_arguments(p.oid) as arguments,
       p.prosrc ilike '%after-sales rework%' and p.prosrc ilike '%"OnlineOrderProductionRework" ar%' as inline_fixed,
       p.prosrc ilike '%_online_order_my_rework_reopened(o."OrderID"%' as still_slow
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_list_online_orders';
