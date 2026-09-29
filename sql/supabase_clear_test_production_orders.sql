-- One-off: clear ALL Production Orders after testing - per "im done testing production orders can we
-- clear the production orders".
--
-- What step 2 does, in one go (all or nothing):
--   * Stock: every posted output that hasn't been reversed yet gets an offsetting ledger entry (same as
--     Item Ledger Entries > Reverse), so the test units leave stock. The ledger itself is append-only -
--     the original + reversal rows stay as history, they just net to zero.
--     EXCEPTION: a serial that was really sold on an order (SoldOnlineOrderId / SoldReceiptNo set) is
--     left alone and its unit is NOT taken out again - that sale already took it out of stock.
--   * Serials the outputs created (IN_STOCK, or SOLD by hand with no order - e.g. the TEST serials
--     cleanup) -> Status REVERSED, UpdatedAtUtc = now(), so the local POS picks the change up on its
--     next serial sync. They are NOT deleted: the POS keeps its own copy and never sees a delete.
--     (So serial numbering continues - the next RS-<item>-26-... number follows the last one used.)
--   * Their shelf placements (Production Shelf Map) are removed.
--   * Every production order is deleted with its lines, rework log and output links - this also drops
--     the online order <-> production order links ("In Production PRD-...").
-- Step 3 resets the PRD counter so the next order is PRD-000001.
--
-- Run step 1 alone first and check it. Then step 2, then step 3.

-- ---------------------------------------------------------------------------
-- 1. Preview (read-only)

-- 1a. The orders that will be deleted.
select o."No", o."Status", o."Description", o."TankMaker", o."StandMaker", o."SourceOnlineOrderId", o."CreatedAtUtc",
       (select count(*) from public."ProductionOrderLines" l where l."ProdOrderNo" = o."No") as lines,
       (select coalesce(sum(l."QtyOutput"), 0) from public."ProductionOrderLines" l where l."ProdOrderNo" = o."No") as qty_output
from public."ProductionOrders" o
order by o."No";

-- 1b. Posted output still in stock (what step 2 takes back out), per entry.
select po."ProdOrderNo", e."EntryNo", e."ItemCode", e."VariantId", e."WarehouseId", e."Quantity" as posted,
       coalesce((select sum(r."Quantity") from public."ItemLedgerEntries" r where r."ReversesEntryNo" = e."EntryNo"), 0) as already_reversed,
       (select count(*) from public."ProductionOrderOutputSerials" os
          join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
          where os."EntryNo" = e."EntryNo"
            and s."Status" = 'SOLD' and (s."SoldOnlineOrderId" is not null or s."SoldReceiptNo" is not null)) as sold_on_an_order
from public."ProductionOrderOutputs" po
join public."ItemLedgerEntries" e on e."EntryNo" = po."EntryNo"
order by po."ProdOrderNo", e."EntryNo";

-- 1c. The serials the outputs created, and what step 2 does with each.
select po."ProdOrderNo", s."SerialNo", s."ItemCode", s."Location", s."Status", s."SoldOnlineOrderId", s."SoldReceiptNo",
       case
         when s."Status" = 'REVERSED' then 'already reversed - no change'
         when s."Status" = 'SOLD' and (s."SoldOnlineOrderId" is not null or s."SoldReceiptNo" is not null) then 'SOLD ON AN ORDER - kept as is'
         else '-> REVERSED'
       end as step_2
from public."ProductionOrderOutputs" po
join public."ProductionOrderOutputSerials" os on os."EntryNo" = po."EntryNo"
join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
order by po."ProdOrderNo", s."SerialNo";

-- ---------------------------------------------------------------------------
-- 2. Clear (one transaction - if anything fails, nothing changes)
do $$
declare
  v_entry record;
  v_remaining numeric;
  v_sold_on_order int;
  v_tx bigint := nextval('public.ile_transaction_no_seq');
  v_reversed_entries int := 0;
  v_reversed_serials int := 0;
  v_orders int;
begin
  -- Stock back out, per output entry.
  for v_entry in
    select e.*, po."ProdOrderNo"
    from public."ProductionOrderOutputs" po
    join public."ItemLedgerEntries" e on e."EntryNo" = po."EntryNo"
    order by e."EntryNo"
  loop
    select count(*) into v_sold_on_order
      from public."ProductionOrderOutputSerials" os
      join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
      where os."EntryNo" = v_entry."EntryNo"
        and s."Status" = 'SOLD' and (s."SoldOnlineOrderId" is not null or s."SoldReceiptNo" is not null);

    v_remaining := v_entry."Quantity"
      + coalesce((select sum(r."Quantity") from public."ItemLedgerEntries" r where r."ReversesEntryNo" = v_entry."EntryNo"), 0)
      - v_sold_on_order;

    if v_remaining > 0 then
      perform public._ile_post(
        v_entry."EntryType", v_entry."ItemCode", v_entry."VariantId", v_entry."WarehouseId", -v_remaining,
        public._ile_today(), coalesce(v_entry."DocumentType", 'Entry') || ' Reversal', v_entry."DocumentNo",
        'Reversal of entry ' || v_entry."EntryNo" || ': test production orders cleared',
        v_tx, 'manual: clear test production orders', v_entry."EntryNo"
      );
      v_reversed_entries := v_reversed_entries + 1;
    end if;
  end loop;

  -- Materials Used on the test orders (supabase_production_order_consumption.sql, if run) go back into
  -- stock the same way.
  if to_regclass('public."ProductionOrderConsumption"') is not null then
    for v_entry in
      select e.*
      from public."ProductionOrderConsumption" c
      join public."ItemLedgerEntries" e on e."EntryNo" = c."EntryNo"
      where not exists (select 1 from public."ItemLedgerEntries" r where r."ReversesEntryNo" = e."EntryNo")
      order by e."EntryNo"
    loop
      perform public._ile_post(
        v_entry."EntryType", v_entry."ItemCode", v_entry."VariantId", v_entry."WarehouseId", -v_entry."Quantity",
        public._ile_today(), coalesce(v_entry."DocumentType", 'Entry') || ' Reversal', v_entry."DocumentNo",
        'Reversal of entry ' || v_entry."EntryNo" || ': test production orders cleared',
        v_tx, 'manual: clear test production orders', v_entry."EntryNo"
      );
      v_reversed_entries := v_reversed_entries + 1;
    end loop;
  end if;

  -- Serials -> REVERSED (kept, so the POS syncs the change), except ones really sold on an order.
  with changed as (
    update public."ItemSerialTracking" s
      set "Status" = 'REVERSED', "UpdatedAtUtc" = now(), "UpdatedBy" = 'manual: clear test production orders'
      from public."ProductionOrderOutputSerials" os
      where os."RunningSerialNo" = s."RunningSerialNo"
        and s."Status" <> 'REVERSED'
        and not (s."Status" = 'SOLD' and (s."SoldOnlineOrderId" is not null or s."SoldReceiptNo" is not null))
      returning 1
  )
  select count(*) into v_reversed_serials from changed;

  -- Shelf placements of those serials.
  delete from public."ProductionShelfSerials" ss
    using public."ProductionOrderOutputSerials" os
    where os."RunningSerialNo" = ss."RunningSerialNo";

  -- The orders (lines + rework cascade) and their output links.
  delete from public."ProductionOrderOutputSerials";
  delete from public."ProductionOrderOutputs";
  delete from public."ProductionOrders";
  get diagnostics v_orders = row_count;

  raise notice 'Deleted % production order(s); reversed % output entr(ies) in ledger transaction %; % serial(s) set to REVERSED.',
    v_orders, v_reversed_entries, v_tx, v_reversed_serials;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Reset the PRD counter (no orders left -> next order is PRD-000001) and check.
select setval('public.production_order_no_seq', 1, false);

select (select count(*) from public."ProductionOrders") as orders_left,
       'PRD-' || lpad((case when is_called then last_value + 1 else last_value end)::text, 6, '0') as next_order_no
from public.production_order_no_seq;
