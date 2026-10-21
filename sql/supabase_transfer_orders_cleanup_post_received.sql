-- ONE-OFF CLEANUP: post the "stuck" Transfer Orders - bucket C of
-- supabase_check_transfer_orders_cleanup_plan.sql that only say "Receive to post".
--
-- These shipped less than requested and the receiver got EVERYTHING that shipped, so under the old
-- rule (posted only when received = Qty To Transfer) they could never leave the live list. The new
-- Receive (supabase_transfer_order_post_partial.sql) would post them as "Partial Received" - this
-- does the same in bulk, so nobody has to open ~29 orders.
--
-- Only orders where, on EVERY line, Shipped = Received (+ any Returned / Written Off), AND the Item
-- Ledger's Transfer Shipment / Receipt totals for the TR match the order exactly. Anything with a
-- short qty or a ledger mismatch is left alone (handle by hand / send to Claude).
--
-- NO stock effect: everything that shipped was already received and posted to the ledger; this only
-- moves the header + lines to Posted_Transfer_Header / Posted_Transfer_Line and removes the live rows
-- (deleting Transfer_Line doesn't fire the ledger trigger - it's AFTER INSERT/UPDATE only).
--
-- Run AFTER supabase_transfer_order_post_partial.sql. Independent of
-- supabase_transfer_orders_cleanup_close_stale.sql (different orders) - either order is fine.
-- All-or-nothing. Safe to re-run - a second run finds nothing left.

drop table if exists _tr_post_received;
create temp table _tr_post_received as
with lines as (
  select l."Document No." as doc,
         sum(coalesce(l."Qty To Transfer", 0)) as to_transfer,
         sum(coalesce(l."Qty Shipped", 0)) as shipped,
         sum(coalesce(l."Qty Received", 0)) as received,
         bool_and(abs(coalesce(l."Qty Shipped", 0) - coalesce(l."Qty Received", 0)
                      - coalesce(l."Qty Returned", 0) - coalesce(l."Qty Written Off", 0)) < 0.001) as all_settled,
         bool_and(coalesce(l."Qty Received", 0) >= coalesce(l."Qty To Transfer", 0)) as all_full
  from public."Transfer_Line" l group by l."Document No."
),
ledger as (
  select e."DocumentNo" as doc,
         sum(case when e."DocumentType" = 'Transfer Shipment' then -e."Quantity" else 0 end) as led_shipped,
         sum(case when e."DocumentType" = 'Transfer Receipt' then e."Quantity" else 0 end) as led_received
  from public."ItemLedgerEntries" e
  where e."DocumentType" in ('Transfer Shipment', 'Transfer Receipt')
  group by e."DocumentNo"
)
select h."No." as doc, case when l.all_full then 'Received' else 'Partial Received' end as new_status
from public."Transfer_Header" h
join lines l on l.doc = h."No."
left join ledger g on g.doc = h."No."
where l.shipped > 0
  and l.all_settled
  and coalesce(h."Status", '') not in ('Cancelled')
  and abs(l.shipped - coalesce(g.led_shipped, 0)) < 0.001
  and abs(l.received - coalesce(g.led_received, 0)) < 0.001;

insert into public."Posted_Transfer_Header" (
  "No.", "Description", "Status", "Requested Date", "Estimated Delivery Date", "Transfer Date", "Receive Date",
  "From Warehouse ID", "From Warehouse", "To Warehouse ID", "To Warehouse", "Category Code",
  "Use Production Category", "Posted Date", "Sent To Online", "Requested By", "Shipped By", "Short Action"
)
select h."No.", h."Description", c.new_status, h."Requested Date", h."Estimated Delivery Date", h."Transfer Date",
       coalesce(h."Receive Date", current_date),
       h."From Warehouse ID", h."From Warehouse", h."To Warehouse ID", h."To Warehouse", h."Category Code",
       h."Use Production Category", now(), h."Sent To Online", h."Requested By", h."Shipped By", null
from public."Transfer_Header" h
join _tr_post_received c on c.doc = h."No."
on conflict ("No.") do nothing;

insert into public."Posted_Transfer_Line" (
  "Document No.", "Item No.", "Variant ID", "Variant Name", "Description", "CategoryCode", "Line No.",
  "Available QTY", "Qty To Transfer", "Qty To Ship", "Qty Shipped", "Qty To Receive", "Qty Received",
  "Qty Returned", "Qty Written Off"
)
select l."Document No.", l."Item No.", l."Variant ID", l."Variant Name", l."Description", l."CategoryCode", l."Line No."::int,
       l."Available QTY", l."Qty To Transfer", l."Qty To Ship", l."Qty Shipped", l."Qty To Receive", l."Qty Received",
       l."Qty Returned", l."Qty Written Off"
from public."Transfer_Line" l
join _tr_post_received c on c.doc = l."Document No."
on conflict ("Document No.", "Line No.") do nothing;

delete from public."Transfer_Line" l using _tr_post_received c where l."Document No." = c.doc;
delete from public."Transfer_Header" h using _tr_post_received c where h."No." = c.doc;

-- Result: how many were posted per status, and what's left live (anything left in C needs a person).
select 'posted as ' || new_status as section, count(*)::text as value,
       array_to_string((array_agg(doc order by doc))[1:10], ', ') as sample
from _tr_post_received group by new_status
union all
select 'still live - ' || coalesce("Status", '(blank)'), count(*)::text,
       array_to_string((array_agg("No." order by "No."))[1:10], ', ')
from public."Transfer_Header" group by "Status";
