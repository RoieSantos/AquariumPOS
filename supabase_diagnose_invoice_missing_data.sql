-- One-off diagnostic for "the Invoice print page shows ₱0.00 everywhere" (Amount per line,
-- Additional NOTE, Total/Discount/Amount Paid/Balance) - checks what's ACTUALLY stored right now
-- in OnlineOrders/OnlineOrderLines for the affected order, so we can tell apart:
--   (a) the data genuinely isn't in Supabase yet (a sync timing/state issue - the fix is to
--       re-sync this order, e.g. the "Sync from Pancake" button on Online Orders), vs
--   (b) the data IS there but admin_get_delivery_receipt/invoice.js isn't reading it correctly
--       (a real code bug worth digging into further).
--
-- Defaults to Order #76357 (Leo Lagon) - the order in the screenshots. Change the order_id value
-- below (just the one CTE) if you're checking a different order.
--
-- Single combined query (not two separate `select`s) - the Supabase SQL editor only displays the
-- LAST statement's result when you run several `select`s together, which silently hid the
-- OnlineOrders header result the first version of this file produced. Pivoting every column into
-- (source, row, field, value) rows via jsonb_each_text lets header + lines show in ONE result
-- grid regardless of how many columns each table has - scroll/filter the "field" column for
-- "NotePrint"/"NotePrintCheckedAt" etc.

with target as (
  select '76357' as order_id
),
header_rows as (
  select o.*
  from public."OnlineOrders" o, target t
  where o."OrderID" = t.order_id
),
line_rows as (
  select l.*
  from public."OnlineOrderLines" l, target t
  where l."OrderID" = t.order_id
)
select 'OnlineOrders header' as source, 1 as row_no, kv.key as field, kv.value
from header_rows h, jsonb_each_text(to_jsonb(h)) as kv

union all

select 'OnlineOrderLines' as source, dense_rank() over (order by l."LineID") as row_no, kv.key as field, kv.value
from line_rows l, jsonb_each_text(to_jsonb(l)) as kv

order by source desc, row_no, field;
