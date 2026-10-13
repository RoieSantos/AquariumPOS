-- READ-ONLY speed check for the Online Orders page (no data or functions are changed).
-- Times each database call the page makes when it opens, so we can see whether the list query
-- itself is slow on the server or the wait was just round trips (fixed in onlineOrders.js v=parallel2).
--
-- HOW TO RUN: replace YOUR_USERNAME / YOUR_PASSWORD below with a real staff login (a Super User is
-- best - same list you see), run the whole file, then CLEAR the password back out before saving -
-- the SQL editor keeps query history.
--
-- Results: one table. "ms" = best of 2 runs, in milliseconds. Safe to re-run any time.

create temp table if not exists _oo_speed (seq int, section text, test text, ms numeric, info text);
truncate _oo_speed;

do $$
declare
  v_user text := 'YOUR_USERNAME';
  v_pw   text := 'YOUR_PASSWORD';
  v_ids  text[];
  v_seq  int := 0;
  v_t    timestamptz;
  v_best numeric;
  v_n    bigint;
  v_sql  text;
  v_fn   text;
  r      int;
  -- Each call the page makes when it opens, as: label | SQL ($1 user, $2 password, $3 order ids)
  v_tests text[][] := array[
    ['password check (is_staff_authorized - runs inside EVERY call)', 'select public.is_staff_authorized($1, $2)::int'],
    ['order list - page 1 of 50, as the page opens it', 'select count(*) from public.admin_list_online_orders(p_admin_username => $1, p_admin_password => $2, p_page => 1, p_page_size => 50, p_branch_scoped => true)'],
    ['order list - page size 1 (compare with 50/200)', 'select count(*) from public.admin_list_online_orders(p_admin_username => $1, p_admin_password => $2, p_page => 1, p_page_size => 1, p_branch_scoped => true)'],
    ['order list - page size 200', 'select count(*) from public.admin_list_online_orders(p_admin_username => $1, p_admin_password => $2, p_page => 1, p_page_size => 200, p_branch_scoped => true)'],
    ['order list - Confirmed tab', 'select count(*) from public.admin_list_online_orders(p_admin_username => $1, p_admin_password => $2, p_status => ''Confirmed'', p_page => 1, p_page_size => 50, p_branch_scoped => true)'],
    ['status pills (status summary)', 'select count(*) from public.admin_get_online_order_status_summary(p_admin_username => $1, p_admin_password => $2, p_branch_scoped => true)']
  ];
  v_detail_fns text[] := array[
    'staff_get_online_order_assignments', 'staff_get_online_order_rework_counts', 'staff_get_online_order_rework',
    'staff_get_online_order_production_done', 'staff_get_online_order_notes', 'staff_list_online_order_production_orders',
    'staff_list_online_order_production_requests', 'staff_list_online_order_release_summary', 'staff_list_online_order_gma_pages'
  ];
begin
  if not public.is_staff_authorized(v_user, v_pw) then
    insert into _oo_speed values (0, '0 setup', 'LOGIN FAILED - fill in YOUR_USERNAME / YOUR_PASSWORD at the top', null, null);
    return;
  end if;

  -- The 50 order ids the detail calls get (page 1 of the list).
  select array_agg(l.order_id) into v_ids
  from public.admin_list_online_orders(p_admin_username => v_user, p_admin_password => v_pw,
                                       p_page => 1, p_page_size => 50, p_branch_scoped => true) l;

  -- 1) Main calls.
  for i in 1 .. array_length(v_tests, 1) loop
    v_best := null;
    begin
      for r in 1 .. 2 loop
        v_t := clock_timestamp();
        execute v_tests[i][2] into v_n using v_user, v_pw;
        v_best := least(coalesce(v_best, 1e12), extract(epoch from clock_timestamp() - v_t) * 1000);
      end loop;
      v_seq := v_seq + 1;
      insert into _oo_speed values (v_seq, '1 page-open calls', v_tests[i][1], round(v_best), v_n || ' row(s)');
    exception when others then
      v_seq := v_seq + 1;
      insert into _oo_speed values (v_seq, '1 page-open calls', v_tests[i][1], null, 'ERROR: ' || sqlerrm);
    end;
  end loop;

  -- 2) The detail calls made for the listed orders (now fired in parallel by the page).
  foreach v_fn in array v_detail_fns loop
    v_best := null;
    v_sql := format('select count(*) from public.%I(p_admin_username => $1, p_admin_password => $2, p_order_ids => $3)', v_fn);
    begin
      for r in 1 .. 2 loop
        v_t := clock_timestamp();
        execute v_sql into v_n using v_user, v_pw, v_ids;
        v_best := least(coalesce(v_best, 1e12), extract(epoch from clock_timestamp() - v_t) * 1000);
      end loop;
      v_seq := v_seq + 1;
      insert into _oo_speed values (v_seq, '2 detail calls (50 orders)', v_fn, round(v_best), v_n || ' row(s)');
    exception when others then
      v_seq := v_seq + 1;
      insert into _oo_speed values (v_seq, '2 detail calls (50 orders)', v_fn, null, 'ERROR: ' || sqlerrm);
    end;
  end loop;

  -- 3) Baseline: just counting/sorting the same orders with none of the per-order extras.
  v_t := clock_timestamp();
  select count(*) into v_n from (
    select o."OrderID" from public."OnlineOrders" o
    where o."ReceivedAtShop" is not true
    order by o."Last_Updated_At" desc nulls last limit 50) x;
  v_seq := v_seq + 1;
  insert into _oo_speed values (v_seq, '3 baseline', 'plain sort of online orders, no extras', round(extract(epoch from clock_timestamp() - v_t) * 1000), null);
end;
$$;

select seq, section, test, ms, info from _oo_speed
union all
select 100, '4 table sizes', 'OnlineOrders (online / walk-in)', null,
       count(*) filter (where "ReceivedAtShop" is not true) || ' online / ' || count(*) filter (where "ReceivedAtShop" is true) || ' walk-in'
from public."OnlineOrders"
union all
select 101, '4 table sizes', 'OnlineOrderLines', null, count(*)::text from public."OnlineOrderLines"
union all
select 200, '5 indexes on OnlineOrders', indexname, null, indexdef
from pg_indexes where schemaname = 'public' and tablename = 'OnlineOrders'
order by 2, 1, 3;
