-- Read-only: why Ready to Ship did / didn't ask for serials on recent advance orders.
-- Covers orders marked To Ship (or Shipped) in the last 3 days. Needs supabase_advance_order_serials.sql.
-- One row per ITEM line (same resolution as the Ready to Ship check, _advance_order_line_items), plus one
-- row per serial already tied to the order.
--   reason "no ..." on every line                 -> nothing to ask (no picker - expected)
--   reason "YES ..." and serial rows              -> tagged (custom-only orders get new serials, no picker)
--   reason "YES ..." and no serial rows           -> the page didn't ask: old cached page, or SQL not run then
--   reason "NO - item not found ..."              -> aquarium / stand / sump we can't match to an item

with recent as (
  select p."TransactionNo", p."ToShipAtUtc", p."ToShipBy"
  from public."AdvanceOrderProduction" p
  where p."ToShipAtUtc" >= now() - interval '3 days'
)
select r."TransactionNo"::text as transaction_no, 'line' as kind, li.line_no,
       coalesce(li.category, '') as category, left(coalesce(li.description, ''), 60) as description,
       coalesce(li.item_code, '(not found)') as item_code, li.reason,
       to_char(r."ToShipAtUtc" at time zone 'Asia/Manila', 'Mon DD HH24:MI') || ' by ' || coalesce(r."ToShipBy", '?') as ready_to_ship
from recent r
cross join lateral public._advance_order_line_items(r."TransactionNo") li
union all
select r."TransactionNo"::text, 'serial', '', coalesce(s."Status", ''), left(coalesce(s."ItemDescription", ''), 60),
       s."SerialNo" || ' (' || s."ItemCode" || ')',
       'already tied: ' || coalesce(nullif(s."SoldOnlineOrderId", ''), 'receipt ' || s."SoldReceiptNo"),
       to_char(s."UpdatedAtUtc" at time zone 'Asia/Manila', 'Mon DD HH24:MI') || ' by ' || coalesce(s."UpdatedBy", '?')
from recent r
cross join lateral public._advance_order_serials(r."TransactionNo") s
order by 1, 2, 3;
