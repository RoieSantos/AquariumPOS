-- Why aren't ADVANCE ORDERS taking stock out of the Item Ledger? Read-only - nothing here writes anything.
--
-- SUPERSEDED by supabase_item_ledger_advance_orders.sql: advance orders no longer go through Pancake - they
-- post to the ledger directly at Ready to Ship (DocumentNo ADV-<TransactionNo>). That file's own result
-- grid is the check now. Kept only as a record of the old Pancake-route diagnosis (15/15 had no OnlineOrderID).
--
-- How an advance order is supposed to deduct: it has no ledger posting of its own. The POS pushes it to
-- Pancake (AdvanceOrders."OnlineOrderID" = the Pancake order id), the Pancake sync brings that order back
-- into OnlineOrders / OnlineOrderLines, and the normal sales reconcile (_ile_reconcile_online_order,
-- supabase_item_ledger_sales.sql) posts its lines as 'Sales Order' entries under that OnlineOrderID.
-- AdvanceOrderLines can't be posted directly: the POS saves the Category (e.g. AQUARIUM) in "No", not the
-- item code.
--
-- This walks that chain for every advance order dated from the day before the sales cutover and says where
-- each one drops out. One grid: 'summary' rows (count per verdict) first, then one 'detail' row per order.

with setup as (
  select s."SalesPostingStartUtc" as start_utc from public."ItemLedgerSetup" s limit 1
),
adv as (
  select a."TransactionNo", a."ReceiptNo", a."Date", a."CustomerName", a."NetAmount", a."Balance",
         nullif(trim(coalesce(a."OnlineOrderID", '')), '') as oid
  from public."AdvanceOrders" a
  cross join setup st
  where st.start_utc is null
     or a."Date" >= (st.start_utc at time zone 'Asia/Manila')::date - 1
),
chk as (
  select
    a.*,
    st.start_utc,
    o."OrderID" as o_id,
    o."Status" as o_status,
    o."LocationID" as o_location,
    o."ConfirmedAtUtc" as o_confirmed,
    o."Date" as o_date,
    (select count(*) from public."AdvanceOrderLines" al where al."TransactionNo" = a."TransactionNo") as adv_lines,
    (select count(*) from public."OnlineOrderLines" l
      where l."OrderID" = a.oid and coalesce(l."Quantity", 0) > 0) as online_lines,
    (select count(*) from public."OnlineOrderLines" l
      left join public."Variants" v on v."VariationId" = l."VariationId"
      cross join lateral public._ile_try_resolve_stock_key(
        coalesce(v."ItemCode", l."ItemCode"), nullif(trim(coalesce(l."VariationId", '')), '')) r
      where l."OrderID" = a.oid and coalesce(l."Quantity", 0) > 0) as stocked_lines,
    (select -sum(e."Quantity") from public."ItemLedgerEntries" e
      where e."DocumentType" = 'Sales Order' and e."DocumentNo" = a.oid) as ledger_qty_out,
    sy."ReconciledAtUtc" as reconciled_at,
    sy."LastError" as last_error
  from adv a
  cross join setup st
  left join public."OnlineOrders" o on a.oid is not null and o."OrderID"::text = a.oid
  left join public."ItemLedgerOrderSync" sy on a.oid is not null and sy."OrderID" = a.oid
),
v as (
  select c.*,
    case
      when c.start_utc is null then '0. Sales posting is OFF (ItemLedgerSetup.SalesPostingStartUtc not set)'
      when c.oid is null then '1. No OnlineOrderID - POS never pushed it to Pancake, so nothing can deduct it'
      when c.o_id is null then '2. Has a Pancake id but the order is not in OnlineOrders (not synced back)'
      when not public._ile_order_counts_as_sale(c.o_status) then '3. Online order status "' || coalesce(c.o_status, '') || '" does not count as a sale'
      when not coalesce(c.o_confirmed >= c.start_utc, c.o_date > (c.start_utc at time zone 'Asia/Manila')::date, false)
        then '4. Confirmed before the sales cutover - assumed already in the counted stock'
      when coalesce(c.o_location, '') = '' then '5. Online order has no LocationID (warehouse)'
      when c.last_error is not null then '6. Reconcile failed: ' || c.last_error
      when c.online_lines = 0 then '7. Online order has no lines in OnlineOrderLines'
      when c.stocked_lines = 0 then '8. None of its lines match a stocked item (custom / service lines only)'
      when coalesce(c.ledger_qty_out, 0) = 0 then '9. Should post but has no ledger entries yet (not reconciled?)'
      else 'OK - deducted'
    end as verdict
  from chk c
)
select 'summary' as section, verdict, count(*)::text as orders,
       null::text as transaction_no, null::text as receipt_no, null::text as adv_date, null::text as customer,
       null::text as online_order_id, null::text as online_status, null::text as location,
       null::text as adv_lines, null::text as online_lines, null::text as stocked_lines, null::text as ledger_qty_out
from v
group by verdict
union all
select 'detail', verdict, null,
       "TransactionNo", "ReceiptNo", "Date"::text, "CustomerName",
       oid, o_status, o_location,
       adv_lines::text, online_lines::text, stocked_lines::text, ledger_qty_out::text
from v
order by 1 desc, 2, 6 desc nulls last;
