-- One-off: writes the Item Ledger entries for transfer order(s) that were shipped/received while
-- General Setup > Item Ledger > "Transfer posting" was switched OFF (so nothing reached the ledger),
-- per direct request ("can you help me write it to transfer order just for now").
--
-- EDIT v_doc_nos BELOW to the transfer order number(s), then run the whole file.
--
-- For each line it compares what the order says with what the ledger already holds and posts only
-- the DIFFERENCE, so running it twice (or on an order that was partly posted) never doubles up:
--   Qty Shipped   -> "Transfer Shipment" entries, minus, at the From Warehouse
--   Qty Received  -> "Transfer Receipt" entries, plus, at the To Warehouse
-- Same entry shape the live trigger writes (supabase_item_ledger_transfer_posting_toggle.sql), dated
-- the order's own Transfer Date / Receive Date when it has one (otherwise today), Posted By
-- "backfill". Works for an open order and for one already posted/archived.
--
-- Unlike a normal shipment it does NOT refuse when the From Warehouse is short - the goods already
-- moved, so refusing would leave the ledger wrong. If that leaves stock negative it is listed at the
-- end so it can be corrected (usually the starting balance was loaded after the shipment).
--
-- Remember to switch "Transfer posting" back ON in General Setup, or the next shipment will be missed too.

do $$
declare
  v_doc_nos text[] := array['TR-Amaya0000173'];   -- <<< the transfer order number(s)
  v_doc text;
  v_line record;
  v_key record;
  v_posted numeric;
  v_delta numeric;
  v_tx bigint;
  v_date date;
  v_found boolean;
  v_entries int := 0;
begin
  foreach v_doc in array v_doc_nos loop
    v_found := false;
    v_tx := null;

    for v_line in
      select l."Item No." as item_no, nullif(trim(coalesce(l."Variant ID", '')), '') as variant_id,
             coalesce(l."Qty Shipped", 0) as qty_shipped, coalesce(l."Qty Received", 0) as qty_received,
             h."From Warehouse ID" as from_id, h."To Warehouse ID" as to_id,
             nullif(h."Transfer Date"::text, '') as ship_date, nullif(h."Receive Date"::text, '') as recv_date,
             h."From Warehouse" as from_name, h."To Warehouse" as to_name
      from public."Transfer_Line" l
      join public."Transfer_Header" h on h."No." = l."Document No."
      where l."Document No." = v_doc
      union all
      select l."Item No.", nullif(trim(coalesce(l."Variant ID", '')), ''),
             coalesce(l."Qty Shipped", 0), coalesce(l."Qty Received", 0),
             h."From Warehouse ID", h."To Warehouse ID",
             nullif(h."Transfer Date"::text, ''), nullif(h."Receive Date"::text, ''),
             h."From Warehouse", h."To Warehouse"
      from public."Posted_Transfer_Line" l
      join public."Posted_Transfer_Header" h on h."No." = l."Document No."
      where l."Document No." = v_doc
        and not exists (select 1 from public."Transfer_Header" x where x."No." = v_doc)
      order by 1
    loop
      v_found := true;
      v_tx := coalesce(v_tx, nextval('public.ile_transaction_no_seq'));

      -- The ledger's own item+variant key, so the comparison below matches how entries were stored.
      select k.item_code, k.variant_id into v_key from public._ile_resolve_stock_key(v_line.item_no, v_line.variant_id) k;

      -- Shipped -> minus at the From Warehouse
      select coalesce(-sum(e."Quantity"), 0) into v_posted
        from public."ItemLedgerEntries" e
       where e."DocumentType" = 'Transfer Shipment' and e."DocumentNo" = v_doc
         and e."ItemCode" = v_key.item_code and coalesce(e."VariantId", '') = coalesce(v_key.variant_id, '')
         and e."WarehouseId" = v_line.from_id;
      v_delta := v_line.qty_shipped - v_posted;
      if v_delta <> 0 then
        v_date := coalesce(v_line.ship_date::date, public._ile_today());
        perform public._ile_post('Transfer', v_line.item_no, v_line.variant_id, v_line.from_id, -v_delta, v_date,
          'Transfer Shipment', v_doc, 'Shipped to ' || coalesce(v_line.to_name, v_line.to_id, '?') || ' (backfilled)',
          v_tx, 'backfill', null, false);
        v_entries := v_entries + 1;
      end if;

      -- Received -> plus at the To Warehouse (only counts once something has shipped)
      if v_line.qty_shipped > 0 then
        select coalesce(sum(e."Quantity"), 0) into v_posted
          from public."ItemLedgerEntries" e
         where e."DocumentType" = 'Transfer Receipt' and e."DocumentNo" = v_doc
           and e."ItemCode" = v_key.item_code and coalesce(e."VariantId", '') = coalesce(v_key.variant_id, '')
           and e."WarehouseId" = v_line.to_id;
        v_delta := v_line.qty_received - v_posted;
        if v_delta <> 0 then
          v_date := coalesce(v_line.recv_date::date, public._ile_today());
          perform public._ile_post('Transfer', v_line.item_no, v_line.variant_id, v_line.to_id, v_delta, v_date,
            'Transfer Receipt', v_doc, 'Received from ' || coalesce(v_line.from_name, v_line.from_id, '?') || ' (backfilled)',
            v_tx, 'backfill');
          v_entries := v_entries + 1;
        end if;
      end if;
    end loop;

    if not v_found then
      raise exception 'Transfer order "%" was not found (open or posted).', v_doc;
    end if;
  end loop;

  raise notice 'Backfill done: % ledger entr% written.', v_entries, case when v_entries = 1 then 'y' else 'ies' end;
end;
$$;

-- What the ledger now holds for these orders (edit the number(s) here too):
select e."EntryNo", e."PostingDate", e."DocumentType", e."DocumentNo", e."ItemCode", e."VariantId", e."WarehouseId", e."Quantity", e."PostedBy"
from public."ItemLedgerEntries" e
where e."DocumentNo" = any (array['TR-Amaya0000173'])
order by e."EntryNo";

-- Anything left negative at the From Warehouse for these items (needs a correction if it returns rows):
select e."ItemCode", e."WarehouseId", sum(e."Quantity") as on_hand
from public."ItemLedgerEntries" e
where (e."ItemCode", e."WarehouseId") in (
  select x."ItemCode", x."WarehouseId" from public."ItemLedgerEntries" x where x."DocumentNo" = any (array['TR-Amaya0000173'])
)
group by e."ItemCode", e."WarehouseId"
having sum(e."Quantity") < 0;
