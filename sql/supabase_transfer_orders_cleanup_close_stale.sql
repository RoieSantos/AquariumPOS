-- ONE-OFF CLEANUP: close the dead Transfer Orders (buckets A + B of
-- supabase_check_transfer_orders_cleanup_plan.sql) by moving them to Posted Transfers with
-- Status "Closed - Cleanup". Nothing is deleted outright - the header + lines are copied to
-- Posted_Transfer_Header / Posted_Transfer_Line first, then removed from the live tables.
--
--   A  pre-ledger leftover : Status not Requested, every line 0 shipped / 0 received, no Item Ledger
--                            entries for the TR (left behind by supabase_item_ledger_wipe_test_data.sql,
--                            which zeroed the lines but not the header Status).
--   B  stale request       : Status Requested, nothing shipped, no ledger entries, requested > 14 days ago.
--
-- NO stock effect: these orders have no ledger entries, and deleting Transfer_Line rows does not fire
-- the ledger trigger (it's AFTER INSERT/UPDATE only). Serials are NOT touched (see the plan check's
-- "serial on A/B order" rows). Orders that really shipped after the ledger started (bucket C) are
-- left alone - clean those by hand with Receive -> Return / Write off.
--
-- Run AFTER supabase_transfer_order_post_partial.sql, and AFTER checking
-- supabase_check_transfer_orders_cleanup_plan.sql. All-or-nothing (one statement block). Safe to
-- re-run - a second run finds nothing left to close.

drop table if exists _tr_cleanup;
create temp table _tr_cleanup as
with lines as (
  select l."Document No." as doc,
         sum(coalesce(l."Qty Shipped", 0)) as shipped,
         sum(coalesce(l."Qty Received", 0)) as received
  from public."Transfer_Line" l group by l."Document No."
)
select h."No." as doc,
       case when coalesce(h."Status", '') <> 'Requested' then 'A' else 'B' end as bucket
from public."Transfer_Header" h
left join lines l on l.doc = h."No."
where coalesce(l.shipped, 0) = 0
  and not exists (select 1 from public."ItemLedgerEntries" e where e."DocumentNo" = h."No.")
  and (
    (coalesce(l.received, 0) = 0 and coalesce(h."Status", '') <> 'Requested')
    or (coalesce(h."Status", '') = 'Requested' and current_date - h."Requested Date" > 14)
  );

insert into public."Posted_Transfer_Header" (
  "No.", "Description", "Status", "Requested Date", "Estimated Delivery Date", "Transfer Date", "Receive Date",
  "From Warehouse ID", "From Warehouse", "To Warehouse ID", "To Warehouse", "Category Code",
  "Use Production Category", "Posted Date", "Sent To Online", "Requested By", "Shipped By", "Short Action"
)
select h."No.", h."Description", 'Closed - Cleanup', h."Requested Date", h."Estimated Delivery Date", h."Transfer Date", h."Receive Date",
       h."From Warehouse ID", h."From Warehouse", h."To Warehouse ID", h."To Warehouse", h."Category Code",
       h."Use Production Category", now(), h."Sent To Online", h."Requested By", h."Shipped By", null
from public."Transfer_Header" h
join _tr_cleanup c on c.doc = h."No."
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
join _tr_cleanup c on c.doc = l."Document No."
on conflict ("Document No.", "Line No.") do nothing;

delete from public."Transfer_Line" l using _tr_cleanup c where l."Document No." = c.doc;
delete from public."Transfer_Header" h using _tr_cleanup c where h."No." = c.doc;

-- Result: how many were closed per bucket, and what's left live.
select 'closed ' || bucket as section, count(*)::text as value,
       array_to_string((array_agg(doc order by doc))[1:10], ', ') as sample
from _tr_cleanup group by bucket
union all
select 'still live - ' || coalesce("Status", '(blank)'), count(*)::text, ''
from public."Transfer_Header" group by "Status";
