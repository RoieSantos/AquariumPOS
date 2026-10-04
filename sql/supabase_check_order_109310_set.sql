-- Read-only: why order 109310 (SET-only, Confirmed) shows no Ready to Ship on the portal.
-- Run AFTER supabase_online_order_set_explode.sql. One result; read the 'section' column top to bottom:
--   setup     - are the SET explosion + SET stock check installed? (has_set_line in the stock check's result)
--   line      - each order line: its category as the portal sees it (must be SET) and the package it resolves to
--   package   - how many packages Supabase has (0 = run local_export_complete_aquarium_sets.sql)
--   part      - the resolved package's parts, and whether each counts as a production item (stock-checked)

with o as (select '109310'::text as order_id),
lines as (
  select l.*, coalesce(nullif(trim(l."ItemCode"), ''), nullif(trim(l."product_display_id"), '')) as code
  from public."OnlineOrderLines" l, o
  where l."OrderID" = o.order_id
),
pkg as (
  select public._resolve_set_package(l."VariationId", l.code) as package_name
  from lines l
  where upper(public._online_order_line_category(l."VariationId", l.code)) = 'SET'
  limit 1
)
select section, name, detail, value
from (
  select 1 as sort, 'setup' as section, 'SET explosion functions' as name, '' as detail,
         case when exists (select 1 from pg_proc where proname = 'staff_save_online_order_set_materials')
              then 'installed' else 'MISSING - run supabase_online_order_set_explode.sql' end as value
  union all
  select 1, 'setup', 'SET stock check (has_set_line)', '',
         case when exists (
           select 1 from pg_proc p
           where p.proname = 'staff_get_online_order_stock_status'
             and 'has_set_line' = any(p.proargnames))
              then 'installed' else 'MISSING - run supabase_online_order_stock_status_set.sql' end
  union all
  select 1, 'setup', 'order header', '',
         coalesce((select 'status ' || coalesce(oo."Status"::text, '?') || ', warehouse ' || coalesce(w."Name"::text, '(none)')
                   from public."OnlineOrders" oo left join public."Warehouses" w on w."ID" = oo."LocationID", o
                   where oo."OrderID"::text = o.order_id), 'ORDER NOT IN OnlineOrders')
  union all
  select 2, 'line', coalesce(l.code, '(no code)') || ' / var ' || coalesce(l."VariationId", '-'),
         coalesce(l."Description", ''),
         'category "' || public._online_order_line_category(l."VariationId", l.code) || '"'
           || case when upper(public._online_order_line_category(l."VariationId", l.code)) = 'SET'
                   then ', package: ' || coalesce(public._resolve_set_package(l."VariationId", l.code), '(none - picked in the SET dialog)')
                   else ' (not SET)' end
  from lines l
  union all
  select 2, 'line', '(order has no lines in OnlineOrderLines)', '', 'open the order once / wait for the sync'
  where not exists (select 1 from lines)
  union all
  select 3, 'package', 'packages in Supabase', '',
         (select count(*)::text from public."CompleteAquariumSetHeader") || ' package(s), '
         || (select count(*)::text from public."CompleteAquariumSetLine") || ' BOM line(s)'
  union all
  select 4, 'part', coalesce(c ->> 'bom_item_no', ''), coalesce(c ->> 'bom_item_name', ''),
         'qty ' || coalesce(c ->> 'quantity', '?')
         || ', default ' || coalesce(c -> 'default' ->> 'item_code', '(none - choose variant)')
         || case when upper(coalesce(c -> 'default' ->> 'item_code', c ->> 'bom_item_no')) like 'AQ-%'
                   or coalesce((select cat."IsProductionCategory" from public."Categories" cat
                                where cat."Code" = nullif(public._online_order_line_category(c -> 'default' ->> 'variation_id',
                                        coalesce(c -> 'default' ->> 'item_code', c ->> 'bom_item_no')), '')), false)
                 then ' - production item (stock-checked)' else ' - not a production item' end
  from pkg
  cross join lateral jsonb_array_elements(public._set_package_components(pkg.package_name, 1)) c
  where pkg.package_name is not null
) x
order by sort, name;
