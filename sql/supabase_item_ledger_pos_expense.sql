-- Item Ledger Entries - POS EXPENSES. Per "if the expense happen it will go in the portal expenses
-- right? can we hook in portal item ledger entry too?".
--
-- When the shop expenses a stocked item on the POS (EXPENSE checkout), the desktop takes it out of
-- its own dbo.ItemLedgerEntry and syncs the entry to public."ExpenseEntryHeader" / "ExpenseEntryLines"
-- (supabase_expense_entry_tables.sql) - but nothing took it out of the portal's ItemLedgerEntries,
-- so portal stock (and Items.QuantityInStock) stayed too high. This hooks those synced lines in.
--
-- HOW IT WORKS - RECONCILE, same idea as sales (supabase_item_ledger_sales.sql). The desktop sync
-- inserts the header, then inserts or PATCHES each line (a re-sync re-sends everything). So for one
-- expense receipt the ledger is brought into line with what its lines currently say:
--     desired = SUM(line Quantity) per stocked item + variant     posted = what the ledger has for it
--     post the DIFFERENCE. A re-sync posts nothing; an edited quantity posts the delta.
-- Triggered straight from ExpenseEntryLines (insert/update) and from ExpenseEntryHeader when its
-- Warehouse changes - no cron needed, the expense sync is already near-real-time.
--
-- ENTRY: EntryType 'Negative Adjmt.' (BC's type for stock used up internally), DocumentType
-- 'POS Expense', DocumentNo = the expense ReceiptNo. Negative stock is allowed (the expense already
-- happened at the shop - it can't be refused, it just shows red on the balances report).
--
-- WHICH LINES: only lines whose ItemCode is a real stocked item. The POS writes incidental
-- expenses (electricity, food, ...) as ItemCode 'INC_EXP' with +1 qty - those aren't items and are
-- skipped. Stocked items arrive with a NEGATIVE quantity, which is posted as-is.
--
-- FROM WHICH WAREHOUSE: ExpenseEntryHeader."Warehouse" (the POS machine's warehouse NAME), matched
-- to Warehouses by name.
--
-- CUTOVER: same switch as sales - nothing posts until ItemLedgerSetup."SalesPostingStartUtc" is set,
-- and only expenses dated after it (or on the cutover day and synced after the cutover moment)
-- count; earlier ones are assumed to be in the stock you counted.
--
-- NEVER BREAKS THE DESKTOP SYNC: a failure (unknown warehouse, ...) is caught and written to
-- ItemLedgerExpenseSync."LastError" instead of failing the POS's insert. Fix the cause, then run
--     select public._ile_reconcile_pos_expense('<ReceiptNo>');
--
-- NOT COVERED: serials. Expensing an aquarium / stand / sump doesn't change its ItemSerialTracking
-- row - mark the serial on the Serial Tracker if one is ever expensed.
--
-- Run AFTER supabase_item_ledger_sales.sql. Safe to re-run. Section 4 posts any already-synced
-- expenses since the cutover (safe: reconcile never double-posts).

-- ============================================================================
-- 1. Per-receipt state (errors)
-- ============================================================================

create table if not exists public."ItemLedgerExpenseSync" (
    "ReceiptNo" varchar(50) primary key,
    "ReconciledAtUtc" timestamptz not null default now(),
    "LastError" text
);

alter table public."ItemLedgerExpenseSync" enable row level security;
revoke all on public."ItemLedgerExpenseSync" from anon, authenticated;

-- ============================================================================
-- 2. Reconcile one expense receipt
-- ============================================================================

create or replace function public._ile_reconcile_pos_expense(p_receipt_no text)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_start timestamptz;
  v_start_day date;
  v_header record;
  v_found boolean;
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
  v_start_day := (v_start at time zone 'Asia/Manila')::date;

  -- One reconcile per receipt at a time (the sync writes several lines back to back).
  perform pg_advisory_xact_lock(hashtext('ile_pos_expense|' || p_receipt_no));

  select h."Date", h."Warehouse", h."SyncedAtUtc" into v_header
    from public."ExpenseEntryHeader" h where h."ReceiptNo" = p_receipt_no;
  v_found := found;

  v_counts := v_found and (
    v_header."Date" > v_start_day
    or (v_header."Date" = v_start_day and coalesce(v_header."SyncedAtUtc" >= v_start, false))
  );

  if v_counts then
    select w."ID" into v_warehouse_id
      from public."Warehouses" w
      where lower(trim(w."Name")) = lower(trim(coalesce(v_header."Warehouse", '')))
      limit 1;
  end if;

  v_first := not exists (
    select 1 from public."ItemLedgerEntries" e where e."DocumentType" = 'POS Expense' and e."DocumentNo" = p_receipt_no
  );

  v_date := case when v_first then coalesce(v_header."Date", public._ile_today()) else public._ile_today() end;

  for v_row in
    with lines as (
      select
        coalesce(v."ItemCode", l."ItemCode") as raw_item,
        nullif(trim(coalesce(l."VariationId", '')), '') as raw_variant,
        l."Quantity" as qty
      from public."ExpenseEntryLines" l
      left join public."Variants" v on v."VariationId" = l."VariationId"
      where v_counts and l."ReceiptNo" = p_receipt_no and coalesce(l."Quantity", 0) <> 0
    ),
    desired as (
      select r.item_code, r.variant_id, sum(li.qty) as qty
      from lines li
      cross join lateral public._ile_try_resolve_stock_key(li.raw_item, li.raw_variant) r
      group by r.item_code, r.variant_id
    ),
    posted as (
      select e."ItemCode" as item_code, e."VariantId" as variant_id, e."WarehouseId" as warehouse_id, sum(e."Quantity") as qty
      from public."ItemLedgerEntries" e
      where e."DocumentType" = 'POS Expense' and e."DocumentNo" = p_receipt_no
      group by e."ItemCode", e."VariantId", e."WarehouseId"
    ),
    -- Anything posted to a different warehouse than the header now says (Warehouse corrected) is
    -- taken back out of there and posted to the right one.
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
      raise exception 'Expense % is from warehouse "%", which is not in Warehouses - its items cannot be taken out of stock.',
        p_receipt_no, coalesce(v_header."Warehouse", '(blank)');
    end if;

    v_transaction_no := coalesce(v_transaction_no, nextval('public.ile_transaction_no_seq'));

    perform public._ile_post(
      'Negative Adjmt.',
      v_row.item_code,
      v_row.variant_id,
      v_row.warehouse_id,
      v_row.delta,
      v_date,
      'POS Expense',
      p_receipt_no,
      case when v_first then 'Expensed on POS ' || p_receipt_no else 'POS expense ' || p_receipt_no || ' changed' end,
      v_transaction_no,
      'system'
    );
    v_posted := v_posted + 1;
  end loop;

  insert into public."ItemLedgerExpenseSync" ("ReceiptNo", "ReconciledAtUtc", "LastError")
  values (p_receipt_no, now(), null)
  on conflict ("ReceiptNo") do update set "ReconciledAtUtc" = now(), "LastError" = null;

  return v_posted;
end;
$$;

revoke execute on function public._ile_reconcile_pos_expense(text) from public, anon, authenticated;

-- Error-safe wrapper: records the failure instead of raising, so the desktop sync never fails.
create or replace function public._ile_try_reconcile_pos_expense(p_receipt_no text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._ile_reconcile_pos_expense(p_receipt_no);
exception when others then
  insert into public."ItemLedgerExpenseSync" ("ReceiptNo", "ReconciledAtUtc", "LastError")
  values (p_receipt_no, now(), sqlerrm)
  on conflict ("ReceiptNo") do update set "ReconciledAtUtc" = now(), "LastError" = excluded."LastError";
end;
$$;

revoke execute on function public._ile_try_reconcile_pos_expense(text) from public, anon, authenticated;

-- ============================================================================
-- 3. Triggers
-- ============================================================================

create or replace function public._ile_pos_expense_line_changed()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public._ile_try_reconcile_pos_expense(new."ReceiptNo");
  return new;
end;
$$;

drop trigger if exists "TR_ExpenseEntryLines_ItemLedger" on public."ExpenseEntryLines";
create trigger "TR_ExpenseEntryLines_ItemLedger"
  after insert or update of "ItemCode", "VariationId", "Quantity" on public."ExpenseEntryLines"
  for each row execute function public._ile_pos_expense_line_changed();

drop trigger if exists "TR_ExpenseEntryHeader_ItemLedger" on public."ExpenseEntryHeader";
create trigger "TR_ExpenseEntryHeader_ItemLedger"
  after update of "Warehouse", "Date" on public."ExpenseEntryHeader"
  for each row
  when (old."Warehouse" is distinct from new."Warehouse" or old."Date" is distinct from new."Date")
  execute function public._ile_pos_expense_line_changed();

-- ============================================================================
-- 4. Catch up: expenses already synced since the cutover
-- ============================================================================

do $$
declare
  v_start timestamptz;
  v_receipt text;
begin
  select s."SalesPostingStartUtc" into v_start from public."ItemLedgerSetup" s limit 1;
  if v_start is null then
    return;
  end if;

  for v_receipt in
    select h."ReceiptNo" from public."ExpenseEntryHeader" h
    where h."Date" >= (v_start at time zone 'Asia/Manila')::date
  loop
    perform public._ile_try_reconcile_pos_expense(v_receipt);
  end loop;
end;
$$;

-- Check: what posted, and anything that failed.
select e."PostingDate", e."DocumentNo", e."ItemCode", e."VariantId", w."Name" as warehouse, e."Quantity"
from public."ItemLedgerEntries" e
left join public."Warehouses" w on w."ID" = e."WarehouseId"
where e."DocumentType" = 'POS Expense'
order by e."EntryNo" desc
limit 50;

select * from public."ItemLedgerExpenseSync" where "LastError" is not null;
