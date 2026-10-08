-- READ-ONLY speed check for the Online Orders page (online-orders.html / admin_list_online_orders).
-- Safe to re-run. Changes no data. It creates two pg_temp helper functions, which disappear when the
-- SQL editor session ends.
--
-- Run the WHOLE file. The final result has these sections:
--   1 rows          - how many orders the default (online, no period) list scans
--   2 timing        - ms for the same list query built different ways:
--                       a_cheap_cols_only       - list without the computed columns (baseline)
--                       b_current_shape         - how admin_list_online_orders does it today: computed
--                                                 columns + count(*) over() + order by + limit 50
--                       c_page_first            - pick the 50 rows first, compute columns for just those
--                       d_roles_x2_all_rows     - only the 2x _online_order_production_roles, every order
--                       e_custom_exists_all     - only the "has custom line" ilike check, every order
--                       f_gma_lookups_all       - only the 2 AutomatedOrders lookups, every order
--                     If b is much slower than a/c, the cost is the computed columns running for every order.
--   3 live_rpc      - real timings Supabase recorded for the page's RPCs (pg_stat_statements):
--                     calls, mean / max ms. Shows which calls are slow in real use.
--   4 plan          - EXPLAIN ANALYZE of b_current_shape (look for "rows=" under the Limit vs. below it)

create or replace function pg_temp.ms(p_sql text) returns numeric language plpgsql as $f$
declare t0 timestamptz; n bigint;
begin
  t0 := clock_timestamp();
  execute p_sql into n;
  return round((extract(epoch from clock_timestamp() - t0) * 1000)::numeric, 1);
end $f$;

create or replace function pg_temp.plan(p_sql text) returns setof text language plpgsql as $f$
declare r record;
begin
  for r in execute 'explain (analyze, buffers, format text) ' || p_sql loop
    return next r."QUERY PLAN";
  end loop;
end $f$;

-- count(x::text) forces every column to really be computed (otherwise Postgres may skip unused ones).
with q as (
  select * from (values
    ('a_cheap_cols_only', $q$
      select count(x::text) from (
        select o."OrderID", o."Status", o."CustomerName", w."Name", tank."DisplayName" tn, stand."DisplayName" sn,
               count(*) over() as total
        from public."OnlineOrders" o
        left join public."Warehouses" w on w."ID" = o."LocationID"
        left join public."StaffUsers" tank on tank."Username" = o."AssignedTankMaker"
        left join public."StaffUsers" stand on stand."Username" = o."AssignedStandMaker"
        where o."ReceivedAtShop" is not true
        order by o."Last_Updated_At" desc nulls last, o."Date" desc nulls last
        limit 50) x $q$),
    ('b_current_shape', $q$
      select count(x::text) from (
        select o."OrderID", o."Status", o."CustomerName", w."Name", tank."DisplayName" tn, stand."DisplayName" sn,
               exists (select 1 from public."OnlineOrderLines" ol where ol."OrderID" = o."OrderID"
                         and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')) as has_custom,
               'tank' = any(public._online_order_production_roles(o."OrderID")) as has_tank,
               'stand' = any(public._online_order_production_roles(o."OrderID")) as has_stand,
               (select ao."GmaPsid" is not null from public."AutomatedOrders" ao where ao."PancakeReceiptNo" = o."OrderID" limit 1) as is_gma,
               (select ao."OrderNo"::text from public."AutomatedOrders" ao where ao."PancakeReceiptNo" = o."OrderID" and ao."GmaPsid" is not null limit 1) as gma_no,
               count(*) over() as total
        from public."OnlineOrders" o
        left join public."Warehouses" w on w."ID" = o."LocationID"
        left join public."StaffUsers" tank on tank."Username" = o."AssignedTankMaker"
        left join public."StaffUsers" stand on stand."Username" = o."AssignedStandMaker"
        where o."ReceivedAtShop" is not true
        order by o."Last_Updated_At" desc nulls last, o."Date" desc nulls last
        limit 50) x $q$),
    ('c_page_first', $q$
      select count(x::text) + (select count(*) from public."OnlineOrders" where "ReceivedAtShop" is not true) * 0 from (
        with page as (
          select o."OrderID", o."Last_Updated_At", o."Date"
          from public."OnlineOrders" o
          where o."ReceivedAtShop" is not true
          order by o."Last_Updated_At" desc nulls last, o."Date" desc nulls last
          limit 50)
        select o."OrderID", o."Status", o."CustomerName", w."Name", tank."DisplayName" tn, stand."DisplayName" sn,
               exists (select 1 from public."OnlineOrderLines" ol where ol."OrderID" = o."OrderID"
                         and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')) as has_custom,
               r.roles,
               (select ao."GmaPsid" is not null from public."AutomatedOrders" ao where ao."PancakeReceiptNo" = o."OrderID" limit 1) as is_gma,
               (select ao."OrderNo"::text from public."AutomatedOrders" ao where ao."PancakeReceiptNo" = o."OrderID" and ao."GmaPsid" is not null limit 1) as gma_no
        from page p
        join public."OnlineOrders" o on o."OrderID" = p."OrderID"
        cross join lateral (select public._online_order_production_roles(o."OrderID") as roles) r
        left join public."Warehouses" w on w."ID" = o."LocationID"
        left join public."StaffUsers" tank on tank."Username" = o."AssignedTankMaker"
        left join public."StaffUsers" stand on stand."Username" = o."AssignedStandMaker") x $q$),
    ('d_roles_x2_all_rows', $q$
      select count(x::text) from (
        select 'tank' = any(public._online_order_production_roles(o."OrderID")) a,
               'stand' = any(public._online_order_production_roles(o."OrderID")) b
        from public."OnlineOrders" o where o."ReceivedAtShop" is not true) x $q$),
    ('e_custom_exists_all', $q$
      select count(x::text) from (
        select exists (select 1 from public."OnlineOrderLines" ol where ol."OrderID" = o."OrderID"
                 and (ol."Description" ilike '%custom%' or ol."ItemCode" ilike '%custom%' or ol."product_display_id" ilike '%custom%')) a
        from public."OnlineOrders" o where o."ReceivedAtShop" is not true) x $q$),
    ('f_gma_lookups_all', $q$
      select count(x::text) from (
        select (select ao."GmaPsid" is not null from public."AutomatedOrders" ao where ao."PancakeReceiptNo" = o."OrderID" limit 1) a,
               (select ao."OrderNo"::text from public."AutomatedOrders" ao where ao."PancakeReceiptNo" = o."OrderID" and ao."GmaPsid" is not null limit 1) b
        from public."OnlineOrders" o where o."ReceivedAtShop" is not true) x $q$)
  ) v(item, sql)
)
select * from (
  select '1 rows' as section, 'online orders (default list scans these)' as item,
         count(*)::numeric as value, null::numeric as max_ms, null::text as note, 0 as ord
  from public."OnlineOrders" where "ReceivedAtShop" is not true
  union all
  select '1 rows', 'walk-in orders', count(*), null, null, 1
  from public."OnlineOrders" where "ReceivedAtShop" is true
  union all
  select '1 rows', 'OnlineOrderLines', count(*), null, null, 2 from public."OnlineOrderLines"
  union all
  select '2 timing', q.item, pg_temp.ms(q.sql), null, 'ms for this query', 10 + row_number() over (order by q.item)::int
  from q
  union all
  select '3 live_rpc', (regexp_match(s.query, '(admin_\w+|staff_\w+|verify_login)'))[1],
         round(s.mean_exec_time::numeric, 1), round(s.max_exec_time::numeric, 1),
         s.calls || ' calls; value = mean ms', 100
  from extensions.pg_stat_statements s
  where s.query ~ '(admin_list_online_orders|admin_get_online_order_status_summary|staff_get_online_order_assignments|staff_get_online_order_rework|staff_get_online_order_production_done|staff_get_online_order_notes|staff_list_online_order_production_orders|staff_list_online_order_release_summary|staff_list_order_makers|staff_search_warehouses|verify_login)'
  union all
  select '4 plan', 'b_current_shape', null, null, p.line, 1000 + p.n::int
  from pg_temp.plan((select replace(sql, 'select count(x::text) from (', 'select * from (') from q where item = 'b_current_shape'))
       with ordinality p(line, n)
) r
order by ord, value desc nulls last;
