-- Check: what does a maker's My Assignments actually return? Runs the LIVE admin_list_online_orders as that
-- maker, the way the page calls it for a maker (p_assigned_to_me = true), without needing their password.
--
-- How: copies the live function into a TEMPORARY function (pg_temp - gone when this query's session ends)
-- with the password checks swapped out (staff check -> true, Super User check -> false, i.e. a normal
-- maker). Nothing real is created or changed.
--
-- Set the maker's username and the order to look for in the two lines marked <<<. One result:
--   summary - rows returned (page of 200) / total, and whether the order is in it (+ its position)
--   row     - every order on the maker's list, in the list's order
-- Safe to re-run.

do $$
declare
  v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'admin_list_online_orders'
  order by p.pronargs desc
  limit 1;

  v_def := replace(v_def, 'FUNCTION public.admin_list_online_orders(', 'FUNCTION pg_temp.check_list_as_maker(');
  v_def := regexp_replace(v_def, 'public\.is_staff_authorized\s*\(\s*p_admin_username\s*,\s*p_admin_password\s*\)', 'true', 'gi');
  v_def := regexp_replace(v_def, 'public\.is_admin_authorized\s*\(\s*p_admin_username\s*,\s*p_admin_password\s*\)', 'false', 'gi');
  execute v_def;
end;
$$;

with params as (
  select 'Lau'::text as maker,        -- <<< maker's username
         '105355'::text as order_id   -- <<< order to look for
),
list as (
  select row_number() over () as pos, l.order_id, l.status, l.total_count
  from params,
       pg_temp.check_list_as_maker(p_admin_username => params.maker, p_admin_password => '',
                                   p_assigned_to_me => true, p_page => 1, p_page_size => 200) l
)
select 'summary'::text as section, null::bigint as pos,
       (select order_id from params) as order_id,
       format('%s row(s) returned, total %s | order on the list: %s',
              (select count(*) from list), coalesce((select max(total_count) from list), 0),
              coalesce((select 'yes, position ' || pos from list where order_id = (select order_id from params)), 'NO')) as detail
union all
select 'row', pos, order_id, status from list
order by 1 desc, 2;
