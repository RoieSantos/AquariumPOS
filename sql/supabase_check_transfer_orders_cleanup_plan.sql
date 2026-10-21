       -- READ-ONLY: what supabase_transfer_orders_cleanup_close_stale.sql WOULD do, in one short result.
       -- Changes nothing. Run this first and check the counts / sample order numbers.
       --
       -- Why the data is dirty: supabase_item_ledger_wipe_test_data.sql (ledger fresh start, ~2026-09-22)
       -- reset EVERY Transfer_Line's Qty Shipped / Qty Received to 0 but left the headers' Status alone. So
       -- old orders still say "Partial Received" / "In-Transit" with nothing shipped or received on their
       -- lines and no ledger entries - they have no stock effect today, they're just clutter.
       --
       -- Buckets (live Transfer_Header rows only):
       --   A  CLOSE - pre-ledger leftover : Status is not Requested, every line 0 shipped / 0 received, and
       --                                    the Item Ledger has nothing for that TR.
       --   B  CLOSE - stale request       : Status Requested, nothing shipped, no ledger entries, older than
       --                                    14 days.
       --   C  KEEP - needs Receive        : real post-ledger shipment (qty shipped > 0 or ledger entries).
       --                                    Clean by hand: open it, Receive -> Return / Write off.
       --   D  KEEP - recent request       : Requested within the last 14 days.
       -- A and B are what the cleanup closes (moved to Posted Transfers as "Closed - Cleanup", not deleted).
       --
       -- Extra rows: each C order (needs a person), serials still IN_TRANSIT on an A/B order (cleanup does
       -- NOT touch serials - fix those in Serial Tracker), and ledger mismatches on C orders.

       with lines as (
       select l."Document No." as doc,
              sum(coalesce(l."Qty To Transfer", 0)) as to_transfer,
              sum(coalesce(l."Qty Shipped", 0)) as shipped,
              sum(coalesce(l."Qty Received", 0)) as received
       from public."Transfer_Line" l group by l."Document No."
       ),
       ledger as (
       select e."DocumentNo" as doc,
              sum(case when e."DocumentType" = 'Transfer Shipment' then -e."Quantity" else 0 end) as led_shipped,
              sum(case when e."DocumentType" = 'Transfer Receipt' then e."Quantity" else 0 end) as led_received,
              count(*) as entries
       from public."ItemLedgerEntries" e
       where e."DocumentNo" in (select "No." from public."Transfer_Header")
       group by e."DocumentNo"
       ),
       b as (
       select h."No." as doc, coalesce(h."Status", '(blank)') as status,
              h."From Warehouse" as from_wh, h."To Warehouse" as to_wh, h."Requested Date" as requested,
              coalesce(l.shipped, 0) as shipped, coalesce(l.received, 0) as received,
              coalesce(g.entries, 0) as entries, coalesce(g.led_shipped, 0) as led_shipped, coalesce(g.led_received, 0) as led_received,
              case
              when coalesce(l.shipped, 0) = 0 and coalesce(l.received, 0) = 0 and coalesce(g.entries, 0) = 0
                     and coalesce(h."Status", '') <> 'Requested' then 'A CLOSE - pre-ledger leftover'
              when coalesce(l.shipped, 0) = 0 and coalesce(g.entries, 0) = 0 and coalesce(h."Status", '') = 'Requested'
                     and current_date - h."Requested Date" > 14 then 'B CLOSE - stale request'
              when coalesce(l.shipped, 0) = 0 and coalesce(g.entries, 0) = 0 and coalesce(h."Status", '') = 'Requested' then 'D KEEP - recent request'
              else 'C KEEP - needs Receive'
              end as bucket
       from public."Transfer_Header" h
       left join lines l on l.doc = h."No."
       left join ledger g on g.doc = h."No."
       ),
       report as (
       select 1 as sort, b.bucket as section, count(*)::text as doc_no,
              'statuses: ' || string_agg(distinct b.status, ', ') as detail,
              'e.g. ' || (array_to_string((array_agg(b.doc order by b.doc))[1:8], ', ')) as sample
       from b group by b.bucket

       union all
       select 2, 'C order (by hand)', b.doc,
              coalesce(b.from_wh, '?') || ' -> ' || coalesce(b.to_wh, '?') || ' | ' || b.status || ' | requested ' || coalesce(b.requested::text, '?')
              || ' | shipped ' || b.shipped || ', received ' || b.received,
              case when abs(b.shipped - b.led_shipped) > 0.001 or abs(b.received - b.led_received) > 0.001
                     then 'LEDGER MISMATCH: ledger shipped ' || b.led_shipped || ', received ' || b.led_received || ' - send to Claude'
                     when b.shipped > b.received then 'Receive -> Return / Write off the ' || (b.shipped - b.received)
                     else 'Receive to post' end
       from b where b.bucket like 'C%'

       union all
       select 3, 'serial on A/B order', s."SourceDocumentNo",
              s."SerialNo" || ' | ' || coalesce(s."ItemCode", '?') || ' | ' || s."Status" || ' | location ' || coalesce(s."Location", '?'),
              'Not touched by cleanup - fix in Serial Tracker (Mark In Stock / Missing)'
       from public."ItemSerialTracking" s
       join b on b.doc = s."SourceDocumentNo" and (b.bucket like 'A%' or b.bucket like 'B%')
       where s."Status" = 'IN_TRANSIT'

       union all
       select 4, 'already in Posted', b.doc, 'A live order with the same No. already exists in Posted Transfers',
              'Cleanup keeps the posted copy and just removes the live one'
       from b join public."Posted_Transfer_Header" p on p."No." = b.doc
       where b.bucket like 'A%' or b.bucket like 'B%'
       )
       select section, doc_no, detail, sample as suggested_action
       from report
       order by sort, section, doc_no;
