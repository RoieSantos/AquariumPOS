-- Read-only. Checks EVERY transaction that should move stock against the Item Ledger, per "check all
-- transaction now if there is a matching item ledger entries.. im missing 4 pcs of items so i wonder if
-- we are missing any write to item ledger entry".
--
-- For each source document, per item + variant + warehouse, compares what the document says should have
-- moved with what the ledger actually has under that document:
--   * Sales Order       - OnlineOrders/OnlineOrderLines since the sales cutover (same rule as the posting
--                         job / _ile_sales_audit). Walk-ins (POS sales via Pancake) are in here too.
--   * POS Expense       - ExpenseEntryHeader/Lines since the cutover (same rule as _ile_reconcile_pos_expense).
--   * Purchase Receipt  - QtyReceived on open AND posted PO lines.
--   * Transfer Shipment - Qty Shipped on open AND posted transfer lines (out of the From warehouse).
--   * Transfer Receipt  - Qty Received on lines the portal shipped (into the To warehouse).
--   * Advance Order     - AdvanceOrders/Lines at To Ship since the cutover (same rule as
--                         _ile_reconcile_advance_order, supabase_item_ledger_advance_orders.sql). Plus section
--                         "3b": advance-order lines NOT deducted yet (not Ready to Ship in the portal) - a paid
--                         order the customer already took is stock that left with no ledger entry.
-- Plus orders / expenses whose last posting attempt ERRORED, and sold lines that could not be tied to a
-- stocked item at all (those are silently skipped by the posting - a real item here = stock never taken out).
--
-- Stock Count, Phys. Inventory, Production, Defect and Assembly entries are written by the same function
-- that posts them, so they can't be "missed" - not checked here.
--
-- HOW TO READ IT (all quantities are stock movements: + into stock, - out of stock):
--   expected_qty = what the document says,  ledger_qty = what the ledger has,
--   missing_qty  = expected - ledger.
--   missing_qty NEGATIVE = an outflow is missing from the ledger -> ledger stock is HIGHER than the shelf.
--   That is the shape of "4 pcs missing on the shelf". The last row per item is a TOTAL across documents.
--
-- POs / transfers are only checked when they have ledger entries OR are dated on/after the ledger's first
-- entry - older documents were already in the opening stock. A PO/transfer that was half received before
-- the ledger existed can still show its pre-ledger part here; a transfer moved while "Transfer Posting" was
-- switched off on General Setup will show as fully missing (that's a real gap too).
-- Orders changed in the last few minutes may still be in the posting queue - see the note column.
--
-- ITEM FILTER: set item_search in "params" below to look at one item (matched against item code / name,
-- variant SKU / name / id - e.g. 'P-012'). Leave it '' for every item. With a filter set, two extra
-- sections show: "0. Ledger balance" (what the ledger says is on hand now, per warehouse) and
-- "5. Ledger history" (every entry for the item, newest first, with the running balance in the note).
--
-- Nothing is written. Safe to re-run.

with
params as (
  select 'A2000'::text as item_search   -- '' = all items
),
picked as (
  select i."Code"::text as item_code
  from public."Items" i, params p
  where p.item_search <> ''
    and (i."Code" ilike '%' || p.item_search || '%' or i."Name" ilike '%' || p.item_search || '%')
  union
  select coalesce(nullif(v."ItemCode", ''), v."MainItemCode")::text
  from public."Variants" v, params p
  where p.item_search <> ''
    and (v."SKU" ilike '%' || p.item_search || '%' or v."VariantName" ilike '%' || p.item_search || '%'
         or v."VariationId" ilike '%' || p.item_search || '%')
),
st as (
  select s."SalesPostingStartUtc" as start_utc
  from public."ItemLedgerSetup" s
  where s."SalesPostingStartUtc" is not null
  limit 1
),
ledger_start as (
  select min(e."PostingDate") as d from public."ItemLedgerEntries" e
),

-- ---------------------------------------------------------------- Sales Orders
so as (
  select o."OrderID"::text as doc_no, o."Date" as doc_date, coalesce(o."LocationID", '')::text as wh,
         o."Status"::text as status, o."SyncedAtUtc" as synced_at,
         public._ile_order_counts_as_sale(o."Status")
           and coalesce(o."ConfirmedAtUtc" >= st.start_utc, o."Date" > (st.start_utc at time zone 'Asia/Manila')::date, false) as counts
  from public."OnlineOrders" o
  cross join st
),
so_exp as (
  select o.doc_no, r.item_code, r.variant_id, o.wh, -sum(l."Quantity") as qty
  from so o
  join public."OnlineOrderLines" l on l."OrderID" = o.doc_no and coalesce(l."Quantity", 0) > 0
  left join public."Variants" v on v."VariationId" = l."VariationId"
  cross join lateral public._ile_try_resolve_stock_key(coalesce(v."ItemCode", l."ItemCode"), nullif(trim(coalesce(l."VariationId", '')), '')) r
  where o.counts and o.wh <> ''
  group by o.doc_no, r.item_code, r.variant_id, o.wh
),
so_led as (
  select e."DocumentNo"::text as doc_no, e."ItemCode"::text as item_code, e."VariantId"::text as variant_id,
         e."WarehouseId"::text as wh, sum(e."Quantity") as qty
  from public."ItemLedgerEntries" e
  where e."DocumentType" = 'Sales Order'
  group by 1, 2, 3, 4
),
so_cmp as (
  select 'Sales Order'::text as document_type, coalesce(x.doc_no, l.doc_no) as doc_no,
         coalesce(x.item_code, l.item_code) as item_code, coalesce(x.variant_id, l.variant_id) as variant_id,
         coalesce(x.wh, l.wh) as wh, coalesce(x.qty, 0) as expected_qty, coalesce(l.qty, 0) as ledger_qty
  from so_exp x
  full join so_led l
    on l.doc_no = x.doc_no and l.item_code = x.item_code
   and l.variant_id is not distinct from x.variant_id and l.wh = x.wh
  where coalesce(x.qty, 0) <> coalesce(l.qty, 0)
),

-- ---------------------------------------------------------------- POS Expenses
ex as (
  select h."ReceiptNo"::text as doc_no, h."Date" as doc_date, h."Warehouse"::text as wh_name,
         (select w."ID"::text from public."Warehouses" w
           where lower(trim(w."Name")) = lower(trim(coalesce(h."Warehouse", ''))) limit 1) as wh,
         (h."Date" > (st.start_utc at time zone 'Asia/Manila')::date
          or (h."Date" = (st.start_utc at time zone 'Asia/Manila')::date and coalesce(h."SyncedAtUtc" >= st.start_utc, false))) as counts
  from public."ExpenseEntryHeader" h
  cross join st
),
ex_exp as (
  select h.doc_no, r.item_code, r.variant_id, h.wh, sum(l."Quantity") as qty
  from ex h
  join public."ExpenseEntryLines" l on l."ReceiptNo" = h.doc_no and coalesce(l."Quantity", 0) <> 0
  left join public."Variants" v on v."VariationId" = l."VariationId"
  cross join lateral public._ile_try_resolve_stock_key(coalesce(v."ItemCode", l."ItemCode"), nullif(trim(coalesce(l."VariationId", '')), '')) r
  where h.counts
  group by h.doc_no, r.item_code, r.variant_id, h.wh
),
ex_led as (
  select e."DocumentNo"::text as doc_no, e."ItemCode"::text as item_code, e."VariantId"::text as variant_id,
         e."WarehouseId"::text as wh, sum(e."Quantity") as qty
  from public."ItemLedgerEntries" e
  where e."DocumentType" = 'POS Expense'
  group by 1, 2, 3, 4
),
ex_cmp as (
  select 'POS Expense'::text, coalesce(x.doc_no, l.doc_no),
         coalesce(x.item_code, l.item_code), coalesce(x.variant_id, l.variant_id),
         coalesce(x.wh, l.wh), coalesce(x.qty, 0), coalesce(l.qty, 0)
  from ex_exp x
  full join ex_led l
    on l.doc_no = x.doc_no and l.item_code = x.item_code
   and l.variant_id is not distinct from x.variant_id and l.wh is not distinct from x.wh
  where coalesce(x.qty, 0) <> coalesce(l.qty, 0)
),

-- ---------------------------------------------------------------- Purchase Receipts (open + posted POs)
po_lines as (
  select pl."PONo"::text as doc_no, po."OrderDate" as doc_date, pl."ItemCode"::text as item, pl."VariantCode"::text as variant,
         pl."WarehouseId"::text as wh, pl."QtyReceived" as qty
  from public."PurchaseOrderLines" pl
  join public."PurchaseOrders" po on po."PONo" = pl."PONo"
  where coalesce(pl."QtyReceived", 0) <> 0
  union all
  select pl."PONo"::text, po."OrderDate", pl."ItemCode"::text, pl."VariantCode"::text, pl."WarehouseId"::text, pl."QtyReceived"
  from public."PostedPurchaseOrderLines" pl
  join public."PostedPurchaseOrders" po on po."PONo" = pl."PONo"
  where coalesce(pl."QtyReceived", 0) <> 0
    and not exists (select 1 from public."PurchaseOrders" o where o."PONo" = pl."PONo")
),
po_led as (
  select e."DocumentNo"::text as doc_no, e."ItemCode"::text as item_code, e."VariantId"::text as variant_id,
         e."WarehouseId"::text as wh, sum(e."Quantity") as qty
  from public."ItemLedgerEntries" e
  where e."DocumentType" = 'Purchase Receipt'
  group by 1, 2, 3, 4
),
po_exp as (
  select p.doc_no, r.item_code, r.variant_id, p.wh, sum(p.qty) as qty
  from po_lines p
  cross join ledger_start ls
  cross join lateral public._ile_try_resolve_stock_key(p.item, nullif(trim(coalesce(p.variant, '')), '')) r
  where p.doc_date >= ls.d or exists (select 1 from po_led l where l.doc_no = p.doc_no)
  group by p.doc_no, r.item_code, r.variant_id, p.wh
),
po_cmp as (
  select 'Purchase Receipt'::text, coalesce(x.doc_no, l.doc_no),
         coalesce(x.item_code, l.item_code), coalesce(x.variant_id, l.variant_id),
         coalesce(x.wh, l.wh), coalesce(x.qty, 0), coalesce(l.qty, 0)
  from po_exp x
  full join po_led l
    on l.doc_no = x.doc_no and l.item_code = x.item_code
   and l.variant_id is not distinct from x.variant_id and l.wh = x.wh
  where coalesce(x.qty, 0) <> coalesce(l.qty, 0)
),

-- ---------------------------------------------------------------- Transfers (open + posted)
tr_lines as (
  select tl."Document No."::text as doc_no,
         case when th."Transfer Date"::text ~ '^\d{4}-\d{2}-\d{2}' then left(th."Transfer Date"::text, 10)::date end as doc_date,
         tl."Item No."::text as item, tl."Variant ID"::text as variant,
         th."From Warehouse ID"::text as from_wh, th."To Warehouse ID"::text as to_wh,
         coalesce(tl."Qty Shipped", 0) as shipped, coalesce(tl."Qty Received", 0) as received
  from public."Transfer_Line" tl
  join public."Transfer_Header" th on th."No." = tl."Document No."
  where coalesce(tl."Qty Shipped", 0) > 0
  union all
  select tl."Document No."::text, th."Transfer Date",
         tl."Item No."::text, tl."Variant ID"::text,
         th."From Warehouse ID"::text, th."To Warehouse ID"::text,
         coalesce(tl."Qty Shipped", 0), coalesce(tl."Qty Received", 0)
  from public."Posted_Transfer_Line" tl
  join public."Posted_Transfer_Header" th on th."No." = tl."Document No."
  where coalesce(tl."Qty Shipped", 0) > 0
    and not exists (select 1 from public."Transfer_Line" o where o."Document No." = tl."Document No.")
),
tr_led as (
  select e."DocumentType"::text as doc_type, e."DocumentNo"::text as doc_no, e."ItemCode"::text as item_code,
         e."VariantId"::text as variant_id, e."WarehouseId"::text as wh, sum(e."Quantity") as qty
  from public."ItemLedgerEntries" e
  where e."DocumentType" in ('Transfer Shipment', 'Transfer Receipt')
  group by 1, 2, 3, 4, 5
),
tr_exp as (
  select m.doc_type, t.doc_no, r.item_code, r.variant_id, m.wh, sum(m.qty) as qty
  from tr_lines t
  cross join ledger_start ls
  cross join lateral (values ('Transfer Shipment', t.from_wh, -t.shipped), ('Transfer Receipt', t.to_wh, t.received)) m(doc_type, wh, qty)
  cross join lateral public._ile_try_resolve_stock_key(t.item, nullif(trim(coalesce(t.variant, '')), '')) r
  where m.qty <> 0
    and (coalesce(t.doc_date >= ls.d, false) or exists (select 1 from tr_led l where l.doc_no = t.doc_no))
  group by m.doc_type, t.doc_no, r.item_code, r.variant_id, m.wh
),
tr_cmp as (
  select coalesce(x.doc_type, l.doc_type), coalesce(x.doc_no, l.doc_no),
         coalesce(x.item_code, l.item_code), coalesce(x.variant_id, l.variant_id),
         coalesce(x.wh, l.wh), coalesce(x.qty, 0), coalesce(l.qty, 0)
  from tr_exp x
  full join tr_led l
    on l.doc_type = x.doc_type and l.doc_no = x.doc_no and l.item_code = x.item_code
   and l.variant_id is not distinct from x.variant_id and l.wh = x.wh
  where coalesce(x.qty, 0) <> coalesce(l.qty, 0)
),

-- ---------------------------------------------------------------- Advance Orders (portal, at To Ship)
adv as (
  select a."TransactionNo"::text as no, ('ADV-' || a."TransactionNo")::text as doc_no, a."Date" as doc_date,
         a."Warehouse"::text as wh_name,
         (select w."ID"::text from public."Warehouses" w
           where lower(trim(w."Name")) = lower(trim(coalesce(a."Warehouse", ''))) limit 1) as wh,
         p."ToShipAtUtc" as to_ship, coalesce(a."FullyPaid", false) as fully_paid,
         exists (select 1 from public."ItemLedgerEntries" e
                  where e."DocumentType" = 'Sales Order'
                    and e."DocumentNo" = nullif(trim(coalesce(a."OnlineOrderID", '')), '')) as via_pancake,
         st.start_utc
  from public."AdvanceOrders" a
  cross join st
  left join public."AdvanceOrderProduction" p on p."TransactionNo" = a."TransactionNo"
),
adv_lines as (
  select a.doc_no, r.item_code, r.variant_id, li.quantity as qty, li.description
  from adv a
  cross join lateral public._advance_order_line_items(a.no) li
  cross join lateral public._ile_try_resolve_stock_key(li.item_code, li.variation_id) r
  where li.item_code is not null and li.reason not like 'no - SET%' and li.quantity > 0
),
adv_exp as (
  select l.doc_no, l.item_code, l.variant_id, a.wh, -sum(l.qty) as qty
  from adv_lines l
  join adv a on a.doc_no = l.doc_no
  where a.to_ship >= a.start_utc and not a.via_pancake
  group by l.doc_no, l.item_code, l.variant_id, a.wh
),
adv_led as (
  select e."DocumentNo"::text as doc_no, e."ItemCode"::text as item_code, e."VariantId"::text as variant_id,
         e."WarehouseId"::text as wh, sum(e."Quantity") as qty
  from public."ItemLedgerEntries" e
  where e."DocumentType" = 'Advance Order'
  group by 1, 2, 3, 4
),
adv_cmp as (
  select 'Advance Order'::text, coalesce(x.doc_no, l.doc_no),
         coalesce(x.item_code, l.item_code), coalesce(x.variant_id, l.variant_id),
         coalesce(x.wh, l.wh), coalesce(x.qty, 0), coalesce(l.qty, 0)
  from adv_exp x
  full join adv_led l
    on l.doc_no = x.doc_no and l.item_code = x.item_code
   and l.variant_id is not distinct from x.variant_id and l.wh is not distinct from x.wh
  where coalesce(x.qty, 0) <> coalesce(l.qty, 0)
),

-- ---------------------------------------------------------------- All mismatches
mism as (
  select * from so_cmp
  union all select * from ex_cmp
  union all select * from po_cmp
  union all select * from tr_cmp
  union all select * from adv_cmp
),
doc_dates as (
  select 'Sales Order'::text as document_type, doc_no, doc_date from so
  union all select 'POS Expense', doc_no, doc_date from ex
  union all select 'Advance Order', doc_no, doc_date from adv
  union all select distinct 'Purchase Receipt', doc_no, doc_date from po_lines
  union all select distinct 'Transfer Shipment', doc_no, doc_date from tr_lines
  union all select distinct 'Transfer Receipt', doc_no, doc_date from tr_lines
),
detail as (
  select
    '1. Mismatch'::text as section,
    m.document_type,
    m.doc_no as document_no,
    d.doc_date,
    m.item_code,
    m.variant_id,
    m.wh as warehouse_id,
    m.expected_qty,
    m.ledger_qty,
    m.expected_qty - m.ledger_qty as missing_qty,
    case
      when m.document_type = 'Sales Order' and o.synced_at > now() - interval '5 minutes' then 'Order changed just now - may still be in the posting queue, re-check in a minute'
      when m.document_type = 'Sales Order' and not o.counts and o.doc_no is not null then 'Order is ' || coalesce(o.status, '?') || ' / before cutover but ledger still has it'
      when m.document_type = 'Sales Order' and o.doc_no is null then 'Order no longer exists but ledger still has it'
      when m.document_type = 'POS Expense' and m.wh is null then 'Expense warehouse "' || coalesce(e.wh_name, '') || '" not found in Warehouses'
      when m.document_type = 'Advance Order' and m.wh is null then 'Advance order warehouse "' || coalesce(ad.wh_name, '') || '" not found in Warehouses'
      when m.document_type = 'Advance Order' and m.ledger_qty = 0 then 'Ready to Ship since cutover, never posted - run supabase_item_ledger_advance_orders.sql'
      when m.ledger_qty = 0 then 'Nothing in the ledger for this - never posted'
      when m.expected_qty = 0 then 'In the ledger but not on the document'
      else 'Ledger quantity differs from the document'
    end as note
  from mism m   -- column names come from so_cmp, the first branch of the union
  left join (select distinct on (document_type, doc_no) * from doc_dates) d
    on d.document_type = m.document_type and d.doc_no = m.doc_no
  left join so o on m.document_type = 'Sales Order' and o.doc_no = m.doc_no
  left join ex e on m.document_type = 'POS Expense' and e.doc_no = m.doc_no
  left join adv ad on m.document_type = 'Advance Order' and ad.doc_no = m.doc_no
),

-- ---------------------------------------------------------------- Posting errors
errs as (
  select '2. Posting error'::text as section, 'Sales Order'::text as document_type, s."OrderID"::text as document_no,
         o.doc_date, null::text as item_code, null::text as variant_id, o.wh as warehouse_id,
         null::numeric as expected_qty, null::numeric as ledger_qty, null::numeric as missing_qty,
         s."LastError"::text as note
  from public."ItemLedgerOrderSync" s
  join so o on o.doc_no = s."OrderID" and o.counts
  where s."LastError" is not null
  union all
  select '2. Posting error', 'POS Expense', s."ReceiptNo"::text, h.doc_date, null, null, h.wh,
         null, null, null, s."LastError"::text
  from public."ItemLedgerExpenseSync" s
  join ex h on h.doc_no = s."ReceiptNo" and h.counts
  where s."LastError" is not null
),

-- ---------------------------------------------------------------- Sold lines that never touched stock
-- The posting skips a line it can't tie to an Items row (custom aquarium, service, ...). Listed so a
-- REAL stocked item that failed to match is visible - those pieces left the shelf with no ledger entry.
unmatched as (
  select '3. Sold line not tied to a stocked item'::text as section, 'Sales Order'::text as document_type,
         o.doc_no as document_no, o.doc_date,
         coalesce(v."ItemCode", l."ItemCode")::text as item_code, nullif(trim(coalesce(l."VariationId", '')), '')::text as variant_id,
         o.wh as warehouse_id, -l."Quantity" as expected_qty, 0::numeric as ledger_qty, -l."Quantity" as missing_qty,
         left(coalesce(l."Description"::text, '') ||' - item/variant not in Items, skipped by the ledger', 300) as note
  from so o
  join public."OnlineOrderLines" l on l."OrderID" = o.doc_no and coalesce(l."Quantity", 0) > 0
  left join public."Variants" v on v."VariationId" = l."VariationId"
  where o.counts and o.wh <> ''
    and (nullif(trim(coalesce(l."ItemCode", '')), '') is not null or nullif(trim(coalesce(l."VariationId", '')), '') is not null)
    and not exists (
      select 1 from public._ile_try_resolve_stock_key(coalesce(v."ItemCode", l."ItemCode"), nullif(trim(coalesce(l."VariationId", '')), ''))
    )
),

-- ---------------------------------------------------------------- Advance-order lines not deducted yet
-- Not a mismatch by the rule (stock leaves at Ready to Ship), but a paid order the customer already took
-- without Ready to Ship in the portal is stock that left the shelf with no ledger entry. Orders that went
-- To Ship before the cutover (already out of the counted stock) or out through Pancake are left out.
adv_pending as (
  select '3b. Advance order line not deducted yet'::text as section, 'Advance Order'::text as document_type,
         a.doc_no as document_no, a.doc_date, l.item_code, l.variant_id, a.wh as warehouse_id,
         -l.qty as expected_qty, 0::numeric as ledger_qty, null::numeric as missing_qty,
         left(case when a.fully_paid
                then 'PAID IN FULL but never Ready to Ship in the portal - if the customer already has it, it was never taken out of stock'
                else 'Open - deducts at Ready to Ship' end
              || ' | ' || coalesce(l.description, ''), 300) as note
  from adv a
  join adv_lines l on l.doc_no = a.doc_no
  where a.to_ship is null and not a.via_pancake
),

-- ---------------------------------------------------------------- Per-item totals of the mismatches
totals as (
  select '4. TOTAL per item'::text as section, 'ALL'::text as document_type, count(*)::text || ' document(s)' as document_no,
         null::date as doc_date, d.item_code, d.variant_id, d.warehouse_id,
         sum(d.expected_qty) as expected_qty, sum(d.ledger_qty) as ledger_qty, sum(d.missing_qty) as missing_qty,
         case when sum(d.missing_qty) < 0 then 'Ledger is HIGHER than it should be by ' || abs(sum(d.missing_qty)) || ' pcs'
              when sum(d.missing_qty) > 0 then 'Ledger is LOWER than it should be by ' || sum(d.missing_qty) || ' pcs'
              else 'Nets to zero' end as note
  from detail d
  group by d.item_code, d.variant_id, d.warehouse_id
),

-- ---------------------------------------------------------------- Item filter only: balance + full history
balance as (
  select '0. Ledger balance'::text as section, 'ALL'::text as document_type, count(*)::text || ' entries' as document_no,
         max(e."PostingDate") as doc_date, e."ItemCode"::text as item_code, e."VariantId"::text as variant_id,
         e."WarehouseId"::text as warehouse_id, null::numeric as expected_qty, sum(e."Quantity") as ledger_qty,
         null::numeric as missing_qty, 'On hand per the ledger - compare with the shelf count'::text as note
  from public."ItemLedgerEntries" e
  where (select item_search from params) <> ''
    and e."ItemCode" in (select item_code from picked)
  group by e."ItemCode", e."VariantId", e."WarehouseId"
),
history as (
  select '5. Ledger history'::text as section, e."DocumentType"::text as document_type, e."DocumentNo"::text as document_no,
         e."PostingDate" as doc_date, e."ItemCode"::text as item_code, e."VariantId"::text as variant_id,
         e."WarehouseId"::text as warehouse_id, null::numeric as expected_qty, e."Quantity" as ledger_qty,
         null::numeric as missing_qty,
         left('#' || e."EntryNo" || ' ' || e."EntryType" || ' | balance after: '
              || sum(e."Quantity") over (partition by e."ItemCode", e."VariantId", e."WarehouseId" order by e."EntryNo")
              || ' | ' || coalesce(e."Description", '') || ' | by ' || coalesce(e."PostedBy", '?')
              || ' ' || to_char(e."PostedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'), 500) as note
  from public."ItemLedgerEntries" e
  where (select item_search from params) <> ''
    and e."ItemCode" in (select item_code from picked)
)

select r.section, r.document_type, r.document_no, r.doc_date, r.item_code,
       i."Name"::text as item_name, r.variant_id, vn."VariantName"::text as variant_name,
       r.warehouse_id, w."Name"::text as warehouse_name,
       r.expected_qty, r.ledger_qty, r.missing_qty, r.note
from (
  select * from detail
  union all select * from errs
  union all select * from unmatched
  union all select * from adv_pending
  union all select * from totals
  union all select * from balance
  union all select * from history
) r
cross join params p
left join public."Items" i on i."Code" = r.item_code
left join public."Variants" vn on vn."VariationId" = r.variant_id
left join public."Warehouses" w on w."ID"::text = r.warehouse_id
-- Item filter: keep posting errors (item unknown) - a failed order could be the one with this item.
-- Section 3 lines aren't in Items (that's why they were skipped), so match them on the text / the item's name too.
where p.item_search = '' or r.item_code is null or r.item_code in (select item_code from picked)
   or (r.section like '3.%' and (r.item_code ilike '%' || p.item_search || '%' or r.note ilike '%' || p.item_search || '%'
       or exists (select 1 from public."Items" i2 where i2."Code" in (select item_code from picked)
                  and r.note ilike '%' || i2."Name" || '%')))
order by r.section, r.doc_date desc nulls last, r.document_no, r.item_code;
