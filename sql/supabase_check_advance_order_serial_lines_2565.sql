-- Read-only: why did Ready to Ship NOT ask for serials on advance order 2565 (MAM JULIE, CUSTOM-AQUARIUM +
-- CUSTOM-STAND, GMA)? Change the number on the "with o" line to check another order.
-- Same idea as supabase_check_advance_order_serial_lines_10382.sql, plus the raw line values and whether
-- the CUSTOM- item codes exist in Items at all.
--   kind 'line'  = _advance_order_line_items' verdict per ITEM line (reason column says why).
--   kind 'raw'   = what the POS actually saved on the line (No / VariationId / Description).
--   kind 'item'  = does an Items row exist for that code (a serial needs a real item code).
--   kind 'serial'= serials already counted as tied to the order.

with o as (select '2565'::text as no)
select 'line' as kind, li.line_no, coalesce(li.category, '') as category,
       left(coalesce(li.description, ''), 70) as description, li.quantity::text as qty,
       coalesce(li.item_code, '(not found)') || coalesce(' / ' || li.variation_id, '') as item_code,
       coalesce(li.resolved_by, '-') as resolved_by, li.reason
from o
cross join lateral public._advance_order_line_items(o.no) li
union all
select 'raw', l."LineNo"::text, coalesce(l."No", '(null)'), left(coalesce(l."Description", ''), 70),
       coalesce(l."Quantity"::text, ''), 'VariationId=' || coalesce(nullif(trim(l."VariationId"), ''), '(none)'),
       coalesce(l."Type", ''), ''
from o
join public."AdvanceOrderLines" l on l."TransactionNo" = o.no
union all
select 'item', '', c.code, coalesce((select left(i."Name", 70) from public."Items" i where i."Code" = c.code), ''),
       '', coalesce((select 'exists, category ' || coalesce(i."CategoryCode", '(none)') from public."Items" i where i."Code" = c.code), 'NOT in Items'),
       '', ''
from (values ('CUSTOM-AQUARIUM'), ('CUSTOM-STAND'), ('CUSTOM_STAND')) as c(code)
union all
select 'serial', '', coalesce(s."Status", ''), left(coalesce(s."ItemDescription", ''), 70), '',
       s."SerialNo" || ' (' || s."ItemCode" || ')', coalesce(s."Location", ''),
       'already tied: ' || coalesce(nullif(s."SoldOnlineOrderId", ''), 'receipt ' || s."SoldReceiptNo")
from o
cross join lateral public._advance_order_serials(o.no) s
order by 1, 2;
