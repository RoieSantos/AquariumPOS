-- READ-ONLY diagnostic: how dirty is the Transfer Order data, and what should happen to each order.
-- Changes nothing. One result (Supabase shows only the last statement), sorted by section:
--
--   1 summary          - live orders per Status.
--   2 open order       - every live order with its totals, age and a suggested action:
--                          * POST NOW        - partially received (needs Receive -> Return / Write off)
--                          * RECEIVE/RETURN  - shipped, nothing received yet
--                          * STALE REQUEST   - nothing shipped, older than 14 days -> cancel/delete
--                          * LEFTOVER        - Status Received/Cancelled but still in the live list
--   3 duplicate?       - two open orders, same From/To, sharing an item (staff re-created instead of
--                        reading the old one).
--   4 ledger mismatch  - the order's Qty Shipped/Received vs what the Item Ledger actually posted for
--                        that TR (posting toggle was off, manual fixes, deleted lines...).
--   5 orphan serial    - serials still IN_TRANSIT whose TR is posted or no longer exists.
--   6 posted short     - posted orders with Shipped > Received that were never returned/written off
--                        (posted before supabase_transfer_order_post_partial.sql).
--
-- Run AFTER supabase_transfer_order_post_partial.sql (uses its Qty Returned / Qty Written Off columns).

with lines as (
  select l."Document No." as doc,
         sum(coalesce(l."Qty To Transfer", 0)) as to_transfer,
         sum(coalesce(l."Qty Shipped", 0)) as shipped,
         sum(coalesce(l."Qty Received", 0)) as received,
         sum(coalesce(l."Qty Returned", 0) + coalesce(l."Qty Written Off", 0)) as settled,
         count(*) as line_count
  from public."Transfer_Line" l
  group by l."Document No."
),
hdr as (
  select h."No." as doc, coalesce(h."Status", '(blank)') as status,
         h."From Warehouse" as from_wh, h."To Warehouse" as to_wh,
         h."Requested Date" as requested, h."Transfer Date" as shipped_on,
         current_date - coalesce(h."Transfer Date", h."Requested Date") as age_days,
         coalesce(l.to_transfer, 0) as to_transfer, coalesce(l.shipped, 0) as shipped,
         coalesce(l.received, 0) as received, coalesce(l.settled, 0) as settled,
         coalesce(l.line_count, 0) as line_count
  from public."Transfer_Header" h
  left join lines l on l.doc = h."No."
),
classified as (
  select h.*,
         case
           when h.status in ('Received', 'Cancelled') then 'LEFTOVER - ' || h.status || ' but still live: archive (Received) or delete (Cancelled)'
           when h.line_count = 0 then 'EMPTY - no lines: delete'
           when h.received > 0 and h.shipped - h.received - h.settled > 0 then 'POST NOW - open Receive, return or write off the short qty'
           when h.received > 0 then 'POST NOW - fully received what shipped: open Receive to post'
           when h.shipped > 0 then 'RECEIVE/RETURN - shipped ' || h.age_days || ' day(s) ago, nothing received: receive it, or Receive 0 + Return/Write off'
           when coalesce(h.age_days, 0) > 14 then 'STALE REQUEST - nothing shipped in ' || h.age_days || ' days: cancel/delete'
           else 'OK - recent request, not shipped yet'
         end as action
  from hdr h
),
ledger as (
  select e."DocumentNo" as doc,
         sum(case when e."DocumentType" = 'Transfer Shipment' then -e."Quantity" else 0 end) as led_shipped,
         sum(case when e."DocumentType" = 'Transfer Receipt' then e."Quantity" else 0 end) as led_received,
         sum(case when e."DocumentType" = 'Transfer Return' then e."Quantity" else 0 end) as led_returned
  from public."ItemLedgerEntries" e
  where e."DocumentType" in ('Transfer Shipment', 'Transfer Receipt', 'Transfer Return')
  group by e."DocumentNo"
),
report as (
  -- 1 summary
  select 1 as sort, '1 summary' as section, status as doc_no,
         count(*) || ' live order(s)' as detail, '' as suggested_action
  from classified group by status

  union all
  -- 2 open orders
  select 2, '2 open order', c.doc,
         coalesce(c.from_wh, '?') || ' -> ' || coalesce(c.to_wh, '?') || ' | ' || c.status
         || ' | requested ' || coalesce(c.requested::text, '?') || ' | lines ' || c.line_count
         || ' | to transfer ' || c.to_transfer || ', shipped ' || c.shipped || ', received ' || c.received
         || case when c.shipped - c.received - c.settled > 0 then ', SHORT ' || (c.shipped - c.received - c.settled) else '' end,
         c.action
  from classified c

  union all
  -- 3 possible duplicates
  select 3, '3 duplicate?', a.doc,
         'same ' || coalesce(a.from_wh, '?') || ' -> ' || coalesce(a.to_wh, '?') || ' as ' || b.doc
         || ' (shared items: ' || (
              select string_agg(distinct la."Item No.", ', ')
              from public."Transfer_Line" la
              join public."Transfer_Line" lb on lb."Document No." = b.doc and lb."Item No." = la."Item No."
              where la."Document No." = a.doc) || ')',
         'Keep the newer one, close the older (' || least(a.doc, b.doc) || ') after checking nothing on it is still coming'
  from classified a
  join classified b
    on b.doc > a.doc and b.from_wh = a.from_wh and b.to_wh = a.to_wh
   and a.status not in ('Received', 'Cancelled') and b.status not in ('Received', 'Cancelled')
  where exists (
    select 1 from public."Transfer_Line" la
    join public."Transfer_Line" lb on lb."Document No." = b.doc and lb."Item No." = la."Item No."
    where la."Document No." = a.doc)

  union all
  -- 4 ledger vs order quantities (live orders)
  select 4, '4 ledger mismatch', c.doc,
         'order: shipped ' || c.shipped || ', received ' || c.received
         || ' | ledger: shipped ' || coalesce(l.led_shipped, 0) || ', received ' || coalesce(l.led_received, 0),
         'Ledger and order disagree - post a correction before closing (do not just delete the order)'
  from classified c
  left join ledger l on l.doc = c.doc
  where abs(c.shipped - coalesce(l.led_shipped, 0)) > 0.001
     or abs(c.received - coalesce(l.led_received, 0)) > 0.001

  union all
  -- 5 orphan IN_TRANSIT serials
  select 5, '5 orphan serial', coalesce(s."SourceDocumentNo", '(none)'),
         s."SerialNo" || ' | ' || coalesce(s."ItemCode", '?') || ' | location ' || coalesce(s."Location", '?')
         || case when p."No." is not null then ' | TR already posted' else ' | TR not found' end,
         'Set back to IN_STOCK at the right warehouse, or MISSING'
  from public."ItemSerialTracking" s
  left join public."Transfer_Header" h on h."No." = s."SourceDocumentNo"
  left join public."Posted_Transfer_Header" p on p."No." = s."SourceDocumentNo"
  where s."Status" = 'IN_TRANSIT' and h."No." is null

  union all
  -- 6 posted with an unsettled shortage
  select 6, '6 posted short', pl."Document No.",
         string_agg(pl."Item No." || ' shipped ' || coalesce(pl."Qty Shipped", 0) || ' / received ' || coalesce(pl."Qty Received", 0), '; '),
         'Units left the sender but never arrived - decide return vs write off (adjustment)'
  from public."Posted_Transfer_Line" pl
  where coalesce(pl."Qty Shipped", 0) - coalesce(pl."Qty Received", 0)
        - coalesce(pl."Qty Returned", 0) - coalesce(pl."Qty Written Off", 0) > 0
  group by pl."Document No."
)
select section, doc_no, detail, suggested_action
from report
order by sort, doc_no;
