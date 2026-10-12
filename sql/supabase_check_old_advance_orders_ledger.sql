-- Old advance orders vs. the Item Ledger - per "how about the old advance order how can we fix this".
-- Read-only - nothing here writes anything.
--
-- Since supabase_item_ledger_advance_orders.sql, an advance order takes its stock out when it reaches To Ship
-- in the portal (AdvanceOrderProduction."ToShipAtUtc" on/after ItemLedgerSetup."SalesPostingStartUtc").
-- This sorts EVERY advance order into the bucket that says what (if anything) is still needed for it:
--
--   A. went To Ship before the cutover   - already out of the counted stock, nothing to do
--   B. through Pancake                    - already deducted under its Online Order ID, nothing to do
--   C. To Ship since the cutover          - posted by the new file (or shows its error / no stocked lines)
--   D. open, not To Ship yet              - will deduct at Ready to Ship, nothing to do now
--   E. fully paid BEFORE the cutover, never To Ship in the portal - most likely picked up before the stock
--      count, so already out of the counted stock. Risk: if someone marks it Ready to Ship now, it would
--      deduct a second time.
--   F. fully paid SINCE the cutover, never To Ship in the portal - most likely handed over at the POS
--      without going through the portal stages, so its stock was NEVER taken out.
--
-- Run AFTER supabase_item_ledger_advance_orders.sql. One grid: 'summary' (count per bucket), then 'detail'
-- for the buckets that may need action (C with a problem, E, F).

with setup as (
  select s."SalesPostingStartUtc" as start_utc from public."ItemLedgerSetup" s limit 1
),
o as (
  select a."TransactionNo", a."ReceiptNo", a."Date", a."CustomerName", a."Warehouse",
         coalesce(a."FullyPaid", false) as fully_paid, a."DatePaid",
         nullif(trim(coalesce(a."OnlineOrderID", '')), '') as oid,
         p."ToShipAtUtc", p."ShippedAtUtc",
         st.start_utc,
         (select -sum(e."Quantity") from public."ItemLedgerEntries" e
           where e."DocumentType" = 'Advance Order' and e."DocumentNo" = 'ADV-' || a."TransactionNo") as adv_qty_out,
         exists (select 1 from public."ItemLedgerEntries" e
                  where e."DocumentType" = 'Sales Order'
                    and e."DocumentNo" = nullif(trim(coalesce(a."OnlineOrderID", '')), '')) as via_pancake,
         (select count(*) from public._advance_order_line_items(a."TransactionNo") li
           cross join lateral public._ile_try_resolve_stock_key(li.item_code, li.variation_id) r
           where li.item_code is not null and li.reason not like 'no - SET%') as stocked_lines,
         sy."LastError" as last_error
  from public."AdvanceOrders" a
  cross join setup st
  left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
  left join public."ItemLedgerAdvanceOrderSync" sy on sy."TransactionNo" = a."TransactionNo"
),
v as (
  select o.*,
    case
      when start_utc is null then '0. Sales posting is OFF'
      when via_pancake then 'B. Deducted through its Pancake order - nothing to do'
      when "ToShipAtUtc" is not null and "ToShipAtUtc" < start_utc then 'A. To Ship before the cutover - nothing to do'
      when "ToShipAtUtc" is not null and last_error is not null then 'C2. To Ship since cutover - POSTING FAILED: ' || last_error
      when "ToShipAtUtc" is not null and coalesce(adv_qty_out, 0) > 0 then 'C1. To Ship since cutover - deducted'
      when "ToShipAtUtc" is not null then 'C3. To Ship since cutover - nothing deducted (no stocked lines)'
      when fully_paid and coalesce("DatePaid" < start_utc, "Date" < (start_utc at time zone 'Asia/Manila')::date, false)
        then 'E. Paid before cutover, never To Ship in portal - likely already out of counted stock'
      when fully_paid then 'F. Paid since cutover, never To Ship in portal - stock NEVER taken out'
      else 'D. Open, not To Ship yet - will deduct at Ready to Ship'
    end as bucket
  from o
)
select 'summary' as section, bucket, count(*)::text as orders,
       null::text as transaction_no, null::text as receipt_no, null::text as order_date, null::text as customer,
       null::text as warehouse, null::text as date_paid, null::text as stocked_lines, null::text as qty_out
from v
group by bucket
union all
select 'detail', bucket, null,
       "TransactionNo", "ReceiptNo", "Date"::text, "CustomerName",
       "Warehouse", ("DatePaid" at time zone 'Asia/Manila')::date::text, stocked_lines::text, adv_qty_out::text
from v
where bucket like 'C2%' or bucket like 'C3%' or bucket like 'E%' or bucket like 'F%'
order by 1 desc, 2, 6 desc nulls last;
