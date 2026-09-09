-- Fixes the New Purchase Order item picker's "Could not choose the best candidate function
-- between: public.staff_search_items(p_admin_username => text, p_admin_password => text,
-- p_search => text, ...)" error (PostgREST PGRST203).
--
-- Cause: more than one staff_search_items overload exists in the database at once. The function
-- has been widened three times - p_page (supabase_warehouses_items_tables.sql), then
-- p_vendor_code (supabase_purchase_order_vendor_item_filter.sql), then the trailing "cost" return
-- column (supabase_item_cost_and_po_line_cost.sql) - and each of those migrations drops the
-- PREVIOUS version by its exact argument-type list. Any older overload whose signature does not
-- match that exact list character-for-character (a different parameter order, an extra parameter,
-- int vs bigint) survives the drop and sits alongside the current one. PostgREST matches an RPC
-- call by argument NAME, so when two surviving overloads both accept the names the portal sends
-- (p_admin_username / p_admin_password / p_search / p_limit / p_vendor_code) it refuses to guess
-- and returns the error above instead of results.
--
-- Fix: drop EVERY public.staff_search_items overload by OID (not by a hard-coded signature, which
-- is what let the stale one survive in the first place), then recreate the single canonical
-- definition - byte-for-byte the one from supabase_item_cost_and_po_line_cost.sql, which is the
-- version both callers expect (Transfer Orders' picker ignores the extra columns; the New
-- Purchase Order picker reads "cost" to prefill a line's Unit Cost).
--
-- Safe to re-run.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'staff_search_items'
  loop
    raise notice 'Dropping overload: %', r.signature;
    execute format('drop function %s', r.signature);
  end loop;
end;
$$;

create or replace function public.staff_search_items(p_admin_username text, p_admin_password text, p_search text default null, p_limit int default 20, p_use_production_category boolean default null, p_page int default 1, p_vendor_code text default null)
returns table(code text, name text, category_code text, quantity_in_stock int, total_count bigint, cost numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
  v_page int := greatest(coalesce(p_page, 1), 1);
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select i."Code"::text, i."Name"::text, i."CategoryCode"::text, i."QuantityInStock",
           count(*) over(), i."Cost"
    from public."Items" i
    left join public."Categories" c on c."Code" = i."CategoryCode"
    where (p_search is null or trim(p_search) = '' or i."Code" ilike '%' || p_search || '%' or i."Name" ilike '%' || p_search || '%')
      and (p_use_production_category is null or coalesce(c."IsProductionCategory", false) = p_use_production_category)
      and not coalesce(c."ExcludeInTransferOrders", false)
      and (p_vendor_code is null or trim(p_vendor_code) = '' or i."VendorCode" = p_vendor_code)
    order by i."Name"
    limit v_limit offset (v_page - 1) * v_limit;
end;
$$;

grant execute on function public.staff_search_items(text, text, text, int, boolean, int, text) to anon;

-- PostgREST caches the schema; without this the old ambiguity can persist for up to ~10 minutes.
notify pgrst, 'reload schema';

-- Verification. Expect EXACTLY ONE row, reading:
--   staff_search_items | p_admin_username text, p_admin_password text, p_search text,
--                        p_limit integer, p_use_production_category boolean, p_page integer,
--                        p_vendor_code text | t
-- More than one row means a drop was blocked (check the NOTICE output above).
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_search_items';

-- The same "widened more than once" history applies to the variant picker next to the Item field,
-- so this checks it too rather than waiting for the same error to surface there. Expect exactly
-- one row; if you get more than one, say so and the same by-OID cleanup can be applied to it.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_search_variants'
order by arguments;
