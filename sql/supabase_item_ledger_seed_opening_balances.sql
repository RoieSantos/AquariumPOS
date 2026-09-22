-- OPTIONAL one-time shortcut: loads today's stock into the Item Ledger as Opening Balance entries by
-- reading the LAST Pancake stock snapshot - use it ONLY if you would rather not upload a count.
--
-- The portal-native way to load starting stock is the "Load or Count Stock (CSV)" section on the
-- Item Ledger Entries page (supabase_item_ledger_stock_count.sql): it needs no Pancake at all - you
-- upload what is on the shelves, from a physical count or any spreadsheet/export you already have.
-- Prefer that. This file exists so the Pancake numbers can be carried over in one go if you want
-- that, and it covers EVERY product (there is no category setup to configure any more).
--
-- It uses the snapshot sitting in public."ItemWarehouseStockCache" - the table the OLD Stock On Hand
-- page's "Refresh from Pancake" button fills (that button is gone from the new page, so this path
-- needs the OLD page, i.e. run it BEFORE deploying the new JS). Nothing here calls Pancake itself.
--
-- ORDER (in one sitting, ideally after closing, so nothing is sold in between):
--   1. Run supabase_item_ledger_entries.sql, supabase_item_ledger_hooks.sql,
--      supabase_item_ledger_sales.sql and supabase_category_drop_stock_sync_flag.sql.
--      (Do NOT deploy the new JS yet.)
--   2. On the OLD Stock On Hand page, click "Refresh from Pancake" and wait for it to finish.
--   3. Run STEP 1 below (preview) and check the numbers look right.
--   4. Run STEP 2 (the seed). It refuses to run twice. It also SWITCHES SALES POSTING ON: from this
--      moment, orders confirmed after now take their stock out of the ledger (earlier orders are
--      already in the Pancake numbers you just loaded), and Items."QuantityInStock" - what Order
--      Now's "In stock" and the AI bot read - is recomputed from the ledger.
--   5. Run STEP 3 to see anything that was skipped, and fix those with a stock count upload.
--   6. Deploy the new JS.
--
-- A note on variants: each row is posted against its Pancake variation. The ledger's stock key
-- normalises that - a variation that is the only one for its item becomes a plain item balance, and
-- items with several variations keep one balance per variation (see _ile_resolve_stock_key in
-- supabase_item_ledger_entries.sql).

-- ============================================================================
-- STEP 1 - PREVIEW (read-only)
-- ============================================================================

select
  count(*) filter (where "RemainQuantity" is not null and "RemainQuantity" <> 0) as rows_to_post,
  count(*) filter (where "RemainQuantity" is null or "RemainQuantity" = 0) as rows_ignored_zero_or_unknown,
  count(distinct "ItemCode") filter (where "RemainQuantity" <> 0) as distinct_items,
  count(distinct "WarehouseId") filter (where "RemainQuantity" <> 0) as distinct_warehouses,
  sum("RemainQuantity") as total_units,
  min("FetchedAtUtc") as snapshot_oldest,
  max("FetchedAtUtc") as snapshot_newest
from public."ItemWarehouseStockCache"
where "ItemCode" is not null;

-- ============================================================================
-- STEP 2 - SEED (writes to the ledger; refuses to run twice)
-- ============================================================================

create table if not exists public."ItemLedgerSeedSkipped" (
    "ItemCode" varchar(200),
    "VariationId" varchar(100),
    "WarehouseId" varchar(100),
    "Quantity" numeric(18, 4),
    "Reason" text
);

alter table public."ItemLedgerSeedSkipped" enable row level security;
revoke all on public."ItemLedgerSeedSkipped" from anon, authenticated;

do $$
declare
  v_row record;
  v_transaction_no bigint;
  v_posted int := 0;
  v_skipped int := 0;
begin
  if exists (select 1 from public."ItemLedgerEntries" where "DocumentType" = 'Opening Balance') then
    raise exception 'Opening balances have already been loaded - this seed only runs once. Correct individual items with an adjustment on the Item Ledger Entries page.';
  end if;

  if not exists (select 1 from public."ItemWarehouseStockCache" where "RemainQuantity" is not null and "RemainQuantity" <> 0) then
    raise exception 'The Pancake stock snapshot is empty - run "Refresh from Pancake" on the old Stock On Hand page first.';
  end if;

  truncate public."ItemLedgerSeedSkipped";
  v_transaction_no := nextval('public.ile_transaction_no_seq');

  for v_row in
    select "ItemCode", "VariationId", "WarehouseId", "RemainQuantity"
    from public."ItemWarehouseStockCache"
    where "ItemCode" is not null and "RemainQuantity" is not null and "RemainQuantity" <> 0
    order by "ItemCode", "WarehouseId"
  loop
    -- One bad row (an item that no longer exists, a warehouse the portal doesn't know) must not
    -- sink the whole load: it is set aside in ItemLedgerSeedSkipped and reported in STEP 3.
    begin
      perform public._ile_post(
        case when v_row."RemainQuantity" > 0 then 'Positive Adjmt.' else 'Negative Adjmt.' end,
        v_row."ItemCode",
        v_row."VariationId",
        v_row."WarehouseId",
        v_row."RemainQuantity",
        public._ile_today(),
        'Opening Balance',
        'OPENING',
        'Opening balance loaded from the Pancake stock snapshot at cutover',
        v_transaction_no,
        'system'
      );
      v_posted := v_posted + 1;
    exception when others then
      insert into public."ItemLedgerSeedSkipped" ("ItemCode", "VariationId", "WarehouseId", "Quantity", "Reason")
      values (v_row."ItemCode", v_row."VariationId", v_row."WarehouseId", v_row."RemainQuantity", sqlerrm);
      v_skipped := v_skipped + 1;
    end;
  end loop;

  -- Sales posting starts from this moment (see supabase_item_ledger_sales.sql), and the catalogue's
  -- stock figure is brought in line with the ledger - items the ledger has no stock of go to 0.
  update public."ItemLedgerSetup" set "SalesPostingStartUtc" = now(), "UpdatedAtUtc" = now();
  perform public._ile_sync_all_item_quantities();

  raise notice 'Opening balances posted: %, skipped: % (see STEP 3). Sales posting is now ON.', v_posted, v_skipped;
end;
$$;

-- ============================================================================
-- STEP 3 - WHAT WAS POSTED, AND WHAT WAS SKIPPED
-- ============================================================================

select count(*) as entries_posted, sum("Quantity") as net_units
from public."ItemLedgerEntries"
where "DocumentType" = 'Opening Balance';

-- Empty = everything loaded. Otherwise fix each with an adjustment on the Item Ledger Entries page
-- (the Reason column says why it was skipped). NB: a fix made AFTER the seed is a normal adjustment,
-- so it needs no special handling.
select * from public."ItemLedgerSeedSkipped" order by "ItemCode", "WarehouseId";

-- Sales posting is on from this timestamp:
select "SalesPostingStartUtc" from public."ItemLedgerSetup";
