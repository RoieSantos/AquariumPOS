-- Delivery calendar: block Mondays again (production day off) - Super Users can still override.
-- Per "can you block the monday on our calendar.. its production day off so we cannot schedule on
-- monday.. only super user can".
--
-- Run AFTER supabase_delivery_allow_monday.sql (already run - it took the old Monday checks out).
--
-- Adds a "Monday + not Super User -> error" check, right after the existing Not authorized check, to the
-- staff booking functions:
--   admin_create_delivery_stop   (Delivery page - Assign to Date)
--   admin_move_delivery_stop     (Move Date)
--   admin_book_delivery_from_pin (Conversations - Delivery Calendar "Book this date")
-- Like supabase_delivery_allow_monday.sql it reads each LIVE definition and edits only that spot, so
-- nothing newer in those functions gets overwritten. Super User = public.is_admin_authorized.
--
-- NOT changed (already block Mondays for everyone, which is what we want - customers aren't Super Users):
--   public_schedule_online_order_delivery, service_book_delivery_from_pin (the AI bot).
-- admin_assign_delivery_date_vendor (per-date vendor tag) is Super User only already, so no check needed.
--
-- If supabase_delivery_assign_automated_order_search.sql, supabase_delivery_stop_route_tagging.sql or
-- supabase_gma_pin_delivery_booking.sql is ever re-run, run this again after.
-- Safe to re-run (a function that already has the check is skipped). Ends with a check:
-- blocks_monday_for_non_super should be true on every row. Needs js/delivery.js and
-- js/gmaConversations.js ?v=dayoff1.

do $$
declare
  r record;
  v_def text;
  v_new text;
  v_date_param text;
begin
  for r in
    select p.oid, p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('admin_create_delivery_stop', 'admin_move_delivery_stop', 'admin_book_delivery_from_pin')
  loop
    v_def := pg_get_functiondef(r.oid);
    if v_def ilike '%production day off%' then
      raise notice '% (oid %) already blocks Mondays - left as is.', r.proname, r.oid;
      continue;
    end if;

    v_date_param := case when r.proname = 'admin_move_delivery_stop' then 'p_new_date' else 'p_delivery_date' end;

    -- First match only (no 'g' flag) - the Not authorized check at the top of the function.
    v_new := regexp_replace(
      v_def,
      'if\s+not\s+public\.is_staff_authorized\s*\(\s*p_admin_username\s*,\s*p_admin_password\s*\)\s+then\s+raise\s+exception\s+''Not authorized\.''\s*;\s*end\s+if\s*;',
      E'\\&\n\n  -- Mondays = production day off; Super Users only (supabase_delivery_block_monday_superuser.sql)\n'
        || '  if extract(dow from ' || v_date_param || ') = 1 and not public.is_admin_authorized(p_admin_username, p_admin_password) then' || E'\n'
        || '    raise exception ''Mondays are production day off - only a Super User can schedule a delivery on a Monday.'';' || E'\n'
        || '  end if;',
      'i');

    if v_new <> v_def then
      execute v_new;
      raise notice 'Added the Monday (production day off) block to % (oid %).', r.proname, r.oid;
    else
      raise warning 'Could not find the Not authorized check in % (oid %) - NOT changed.', r.proname, r.oid;
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';

-- Check: true = Mondays blocked for everyone but Super Users (bot functions: true = blocked for everyone).
select p.proname::text as function_name,
       pg_get_function_identity_arguments(p.oid) as arguments,
       (p.prosrc ilike '%production day off%' or p.prosrc ilike '%Mondays are not available%') as blocks_monday_for_non_super
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('admin_create_delivery_stop', 'admin_move_delivery_stop', 'admin_book_delivery_from_pin',
                    'public_schedule_online_order_delivery', 'service_book_delivery_from_pin')
order by 1, 2;
