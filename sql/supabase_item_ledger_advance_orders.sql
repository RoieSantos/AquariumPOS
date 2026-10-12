-- Item Ledger Entries - ADVANCE ORDERS. Per "can we cut the pancake push and only push to portal then? ...
-- when an advance order has been to-ship ... that time we will deduct to item ledger entry directly
-- (No pancake needed)".
--
-- Before: an advance order only left the ledger through the Pancake order the POS created for it
-- (AdvanceOrders."OnlineOrderID" -> OnlineOrders -> 'Sales Order' entries). That link was blank on every
-- advance order since the cutover (supabase_diagnose_item_ledger_advance_orders.sql), so none deducted.
-- The POS no longer pushes advance orders to Pancake at all (MainForm.cs / AdvanceOrdersHeaderForm.cs /
-- AdvanceOrderLinesForm.cs) - the portal owns them.
--
-- Now: when an advance order reaches To Ship (Ready to Ship on the Advance Orders tab -
-- AdvanceOrderProduction."ToShipAtUtc"), its lines are posted straight to the ledger:
--   EntryType 'Sale', DocumentType 'Advance Order', DocumentNo 'ADV-<TransactionNo>' (same link the serials
--   use - TransactionNo is unique, ReceiptNos repeat across stores), from AdvanceOrders."Warehouse" (the
--   POS's warehouse NAME, matched to Warehouses."Name").
--
-- RECONCILE, like sales and POS expenses: desired = the order's stocked lines while it's at To Ship (or
-- later); posted = what the ledger has for ADV-<no>; post the difference. So Undo Stage back before To Ship
-- puts the stock back, a line the POS edits afterwards posts the delta, and running it twice posts nothing.
--
-- WHICH LINES: AdvanceOrderLines."No" is the POS's Category, not the item code, so each line's item is
-- resolved by _advance_order_line_items (supabase_advance_order_serials.sql: VariationId, then "No" as an
-- item code, then the Description as an item / variant name). Lines that resolve to no stocked item are
-- skipped (custom builds, services). A SET line (the mother item, e.g. AQUARIUM SET) is skipped too: the POS
-- already explodes the set into its BOM parts as their own 0-price lines at the time of sale
-- (MainForm.cs AddAquariumSetToSale), and those part lines carry the stock - no BOM step is needed here.
--
-- CUTOVER: same switch as sales (ItemLedgerSetup."SalesPostingStartUtc"). Only an order whose To Ship time
-- is after it posts. Orders already at To Ship / Shipped since then are posted by section 5 below (they
-- were never deducted).
--
-- An advance order that DID go out through its Pancake order ('Sales Order' entries under its
-- OnlineOrderID) is skipped, so it can never be taken out twice.
--
-- ERRORS: Ready to Ship itself fails with the reason (e.g. the order's warehouse isn't in Warehouses) - the
-- stage change and any serials picked roll back with it. A later POS line sync never fails; its error is
-- kept in ItemLedgerAdvanceOrderSync."LastError".
--
-- Don't reverse these entries by hand on the Item Ledger page - the next reconcile would post them again.
-- Undo Stage on the order (or edit it on the POS) instead.
--
-- Run AFTER supabase_item_ledger_sales.sql, supabase_advance_order_serials.sql (_advance_order_line_items)
-- and supabase_advance_orders_warehouse_field.sql. Safe to re-run. Needs js/onlineOrders.js and
-- js/itemLedgerEntries.js ?v=adv-ile1.

-- ============================================================================
-- 1. Per-order state (errors)
-- ============================================================================

create table if not exists public."ItemLedgerAdvanceOrderSync" (
    "TransactionNo" varchar(100) primary key,
    "ReconciledAtUtc" timestamptz not null default now(),
    "LastError" text
);

alter table public."ItemLedgerAdvanceOrderSync" enable row level security;
revoke all on public."ItemLedgerAdvanceOrderSync" from anon, authenticated;

-- ============================================================================
-- 2. Reconcile one advance order
-- ============================================================================

create or replace function public._ile_reconcile_advance_order(p_no text)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_start timestamptz;
  v_doc text := 'ADV-' || p_no;
  v_order record;
  v_found boolean;
  v_to_ship timestamptz;
  v_counts boolean;
  v_warehouse_id text;
  v_first boolean;
  v_date date;
  v_transaction_no bigint;
  v_row record;
  v_posted int := 0;
begin
  select s."SalesPostingStartUtc" into v_start from public."ItemLedgerSetup" s limit 1;
  if v_start is null then
    return 0;
  end if;

  -- One reconcile per order at a time (the POS sync writes several lines back to back).
  perform pg_advisory_xact_lock(hashtext('ile_advance|' || p_no));

  select a."Warehouse", nullif(trim(coalesce(a."OnlineOrderID", '')), '') as online_order_id into v_order
    from public."AdvanceOrders" a where a."TransactionNo" = p_no;
  v_found := found;

  select p."ToShipAtUtc" into v_to_ship
    from public."AdvanceOrderProduction" p where p."TransactionNo" = p_no;

  v_counts := v_found
    and v_to_ship is not null and v_to_ship >= v_start
    -- Already taken out through its old Pancake order - never twice.
    and not (v_order.online_order_id is not null and exists (
      select 1 from public."ItemLedgerEntries" e
      where e."DocumentType" = 'Sales Order' and e."DocumentNo" = v_order.online_order_id));

  if v_counts then
    select w."ID" into v_warehouse_id
      from public."Warehouses" w
      where lower(trim(w."Name")) = lower(trim(coalesce(v_order."Warehouse", '')))
      limit 1;
  end if;

  v_first := not exists (
    select 1 from public."ItemLedgerEntries" e where e."DocumentType" = 'Advance Order' and e."DocumentNo" = v_doc
  );

  -- First posting dated to the day it went To Ship; later corrections dated today.
  v_date := case
    when v_first and v_to_ship is not null then (v_to_ship at time zone 'Asia/Manila')::date
    else public._ile_today()
  end;

  for v_row in
    with lines as (
      select li.item_code as raw_item, li.variation_id as raw_variant, li.quantity as qty
      from public._advance_order_line_items(p_no) li
      where v_counts
        and li.item_code is not null
        and li.reason not like 'no - SET%'
        and li.quantity > 0
    ),
    desired as (
      select r.item_code, r.variant_id, sum(li.qty) as qty
      from lines li
      cross join lateral public._ile_try_resolve_stock_key(li.raw_item, li.raw_variant) r
      group by r.item_code, r.variant_id
    ),
    posted as (
      select e."ItemCode" as item_code, e."VariantId" as variant_id, e."WarehouseId" as warehouse_id, -sum(e."Quantity") as qty
      from public."ItemLedgerEntries" e
      where e."DocumentType" = 'Advance Order' and e."DocumentNo" = v_doc
      group by e."ItemCode", e."VariantId", e."WarehouseId"
    ),
    -- Anything posted to a different warehouse than the order now says is put back there and taken
    -- from the right one.
    wanted as (
      select d.item_code, d.variant_id, v_warehouse_id as warehouse_id, d.qty from desired d
    )
    select
      coalesce(w.item_code, p.item_code) as item_code,
      coalesce(w.variant_id, p.variant_id) as variant_id,
      coalesce(w.warehouse_id, p.warehouse_id) as warehouse_id,
      coalesce(w.qty, 0) - coalesce(p.qty, 0) as delta
    from wanted w
    full join posted p
      on w.item_code = p.item_code
     and w.variant_id is not distinct from p.variant_id
     and w.warehouse_id = p.warehouse_id
    where coalesce(w.qty, 0) - coalesce(p.qty, 0) <> 0
  loop
    if v_row.warehouse_id is null then
      raise exception 'Advance order % is from warehouse "%", which is not in Warehouses - its items cannot be taken out of stock.',
        p_no, coalesce(v_order."Warehouse", '(blank)');
    end if;

    v_transaction_no := coalesce(v_transaction_no, nextval('public.ile_transaction_no_seq'));

    perform public._ile_post(
      'Sale',
      v_row.item_code,
      v_row.variant_id,
      v_row.warehouse_id,
      -v_row.delta,
      v_date,
      'Advance Order',
      v_doc,
      case
        when v_first then 'Advance order ' || p_no || ' ready to ship'
        when v_counts then 'Advance order ' || p_no || ' changed'
        else 'Advance order ' || p_no || ' back before To Ship'
      end,
      v_transaction_no,
      'system'
    );
    v_posted := v_posted + 1;
  end loop;

  insert into public."ItemLedgerAdvanceOrderSync" ("TransactionNo", "ReconciledAtUtc", "LastError")
  values (p_no, now(), null)
  on conflict ("TransactionNo") do update set "ReconciledAtUtc" = now(), "LastError" = null;

  return v_posted;
end;
$$;

revoke execute on function public._ile_reconcile_advance_order(text) from public, anon, authenticated;

-- Error-safe wrapper for the POS sync: records the failure instead of raising.
create or replace function public._ile_try_reconcile_advance_order(p_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._ile_reconcile_advance_order(p_no);
exception when others then
  insert into public."ItemLedgerAdvanceOrderSync" ("TransactionNo", "ReconciledAtUtc", "LastError")
  values (p_no, now(), sqlerrm)
  on conflict ("TransactionNo") do update set "ReconciledAtUtc" = now(), "LastError" = excluded."LastError";
end;
$$;

revoke execute on function public._ile_try_reconcile_advance_order(text) from public, anon, authenticated;

-- ============================================================================
-- 3. Triggers
-- ============================================================================

-- Stage change (Ready to Ship / Undo Stage): errors fail the stage change itself.
create or replace function public._ile_advance_order_stage_changed()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._ile_reconcile_advance_order(new."TransactionNo");
  return new;
end;
$$;

drop trigger if exists "TR_AdvanceOrderProduction_ItemLedger" on public."AdvanceOrderProduction";
create trigger "TR_AdvanceOrderProduction_ItemLedger"
  after insert or update of "ToShipAtUtc" on public."AdvanceOrderProduction"
  for each row execute function public._ile_advance_order_stage_changed();

-- POS sync (lines / header warehouse): never fails the sync.
create or replace function public._ile_advance_order_synced()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_no text := case when tg_op = 'DELETE' then old."TransactionNo" else new."TransactionNo" end;
begin
  -- Only orders already at To Ship (or once posted) have anything to reconcile.
  if exists (select 1 from public."AdvanceOrderProduction" p where p."TransactionNo" = v_no and p."ToShipAtUtc" is not null)
     or exists (select 1 from public."ItemLedgerEntries" e where e."DocumentType" = 'Advance Order' and e."DocumentNo" = 'ADV-' || v_no) then
    perform public._ile_try_reconcile_advance_order(v_no);
  end if;
  return null;
end;
$$;

drop trigger if exists "TR_AdvanceOrderLines_ItemLedger" on public."AdvanceOrderLines";
create trigger "TR_AdvanceOrderLines_ItemLedger"
  after insert or delete or update of "No", "Description", "VariationId", "Quantity", "Type" on public."AdvanceOrderLines"
  for each row execute function public._ile_advance_order_synced();

drop trigger if exists "TR_AdvanceOrders_ItemLedger" on public."AdvanceOrders";
create trigger "TR_AdvanceOrders_ItemLedger"
  after update of "Warehouse" on public."AdvanceOrders"
  for each row
  when (old."Warehouse" is distinct from new."Warehouse")
  execute function public._ile_advance_order_synced();

-- ============================================================================
-- 4. Show Document / Item Ledger button need nothing else (DocumentNo = ADV-<TransactionNo>).
-- ============================================================================

-- ============================================================================
-- 5. Catch up: advance orders already at To Ship / Shipped since the cutover, never deducted
-- ============================================================================

do $$
declare
  v_no text;
begin
  for v_no in
    select p."TransactionNo"
    from public."AdvanceOrderProduction" p
    cross join public."ItemLedgerSetup" s
    where s."SalesPostingStartUtc" is not null
      and p."ToShipAtUtc" >= s."SalesPostingStartUtc"
    order by p."ToShipAtUtc"
  loop
    perform public._ile_try_reconcile_advance_order(v_no);
  end loop;
end;
$$;

notify pgrst, 'reload schema';

-- Result: what the catch-up posted, per advance order at To Ship / Shipped since the cutover.
select p."TransactionNo" as transaction_no,
       a."Warehouse" as warehouse,
       p."ToShipAtUtc" as to_ship_at,
       coalesce((select -sum(e."Quantity") from public."ItemLedgerEntries" e
                 where e."DocumentType" = 'Advance Order' and e."DocumentNo" = 'ADV-' || p."TransactionNo"), 0) as qty_out,
       sy."LastError" as last_error
from public."AdvanceOrderProduction" p
cross join public."ItemLedgerSetup" s
left join public."AdvanceOrders" a on a."TransactionNo" = p."TransactionNo"
left join public."ItemLedgerAdvanceOrderSync" sy on sy."TransactionNo" = p."TransactionNo"
where s."SalesPostingStartUtc" is not null
  and p."ToShipAtUtc" >= s."SalesPostingStartUtc"
order by sy."LastError" is null, p."ToShipAtUtc" desc;
