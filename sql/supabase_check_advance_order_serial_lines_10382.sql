-- Read-only: will Ready to Ship ask for serials on advance order 10382? (change the number on the next
-- line to check another order). Needs supabase_advance_order_serials.sql (_advance_order_line_items).
-- One row per ITEM line: "category" is what the POS saved as Item No. (its Category column),
-- "item_code" is the real item resolved from VariationId / item code / name, "reason" says why it does
-- or doesn't need a serial. Then one row per serial already tied to the order.
--   reason "NO - item not found ..." = an aquarium / stand / sump line we can't match to an item: its
--   VariationId and Description don't match any Items / Variants row in the portal.

with o as (select '10382'::text as no)
select 'line' as kind, li.line_no, coalesce(li.category, '') as category,
       left(coalesce(li.description, ''), 70) as description, li.quantity::text as qty,
       coalesce(li.item_code, '(not found)') || coalesce(' / ' || li.variation_id, '') as item_code,
       coalesce(li.resolved_by, '-') as resolved_by, li.reason
from o
cross join lateral public._advance_order_line_items(o.no) li
union all
select 'serial', '', coalesce(s."Status", ''), left(coalesce(s."ItemDescription", ''), 70), '',
       s."SerialNo" || ' (' || s."ItemCode" || ')', coalesce(s."Location", ''),
       'already tied: ' || coalesce(nullif(s."SoldOnlineOrderId", ''), 'receipt ' || s."SoldReceiptNo")
from o
cross join lateral public._advance_order_serials(o.no) s
order by 1, 2;
