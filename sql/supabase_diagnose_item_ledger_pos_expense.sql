-- Why didn't ONE POS expense take its stock out of the Item Ledger? Read-only - nothing here writes
-- anything (the one helper is a pg_temp function, gone when the session ends).
--
-- Walks every condition _ile_reconcile_pos_expense (supabase_item_ledger_pos_expense.sql) needs, in
-- order, and says which one the expense fails. Same idea as supabase_diagnose_item_ledger_order.sql
-- for orders.
--
-- Run the whole file in the Supabase SQL editor - it shows one grid; the first 'FAIL' is your answer.
-- As is, it checks the most recently synced expense that has a real item on it. To check a specific
-- one, put its receipt number between the quotes on the last "select" line (search for RECEIPT-NO).

create or replace function pg_temp.ile_expense_diagnose(p_receipt_no text)
returns table(step int, check_name text, result text, detail text)
language plpgsql
as $$
declare
  v_receipt text := nullif(trim(coalesce(p_receipt_no, '')), '');
  v_start timestamptz;
  v_start_day date;
  v_header record;
  v_found boolean := false;
  v_has_function boolean;
  v_trigger_state text;
  v_warehouse_id text;
  v_sync_found boolean := false;
  v_error text;
  v_reconciled timestamptz;
  v_line record;
  v_item text;
  v_variant text;
  v_reason text;
  v_n int := 0;
  v_posted_count int;
  v_posted_qty numeric;
begin
  if v_receipt is null then
    select h."ReceiptNo" into v_receipt
      from public."ExpenseEntryHeader" h
     where exists (select 1 from public."ExpenseEntryLines" l
                    where l."ReceiptNo" = h."ReceiptNo" and coalesce(l."ItemCode", '') <> 'INC_EXP')
     order by h."SyncedAtUtc" desc nulls last
     limit 1;
  end if;

  step := 0; check_name := 'Expense being checked'; result := 'info';
  detail := coalesce(v_receipt, 'No synced expense with a real item on it was found (every line is INC_EXP = incidental, never stock)');
  return next;
  if v_receipt is null then
    return;
  end if;

  -- 1. Is the hook there at all?
  v_has_function := to_regprocedure('public._ile_reconcile_pos_expense(text)') is not null;
  select case t.tgenabled when 'D' then 'disabled' else 'on' end into v_trigger_state
    from pg_trigger t
   where t.tgrelid = 'public."ExpenseEntryLines"'::regclass
     and t.tgname = 'TR_ExpenseEntryLines_ItemLedger' and not t.tgisinternal;

  step := 1; check_name := 'Expense hook is installed';
  result := case when v_has_function and coalesce(v_trigger_state, '') = 'on' then 'ok' else 'FAIL' end;
  detail := 'Function ' || case when v_has_function then 'present' else 'MISSING' end
    || ', trigger on ExpenseEntryLines ' || coalesce(v_trigger_state, 'MISSING')
    || case when result = 'FAIL' then ' - run supabase_item_ledger_pos_expense.sql (it also catches up expenses already synced)' else '' end;
  return next;

  -- 2. Posting switched on
  if to_regclass('public."ItemLedgerSetup"') is not null then
    select s."SalesPostingStartUtc" into v_start from public."ItemLedgerSetup" s limit 1;
  end if;
  v_start_day := (v_start at time zone 'Asia/Manila')::date;

  step := 2; check_name := 'Stock posting switched on';
  result := case when v_start is not null then 'ok' else 'FAIL' end;
  detail := 'Posting starts ' || coalesce((v_start at time zone 'Asia/Manila')::text,
    'NEVER - press "Start Posting Sales From Now" on Item Ledger Entries (expenses use the same switch)');
  return next;

  -- 3. Header synced
  select h."Date", h."Warehouse", h."SyncedAtUtc", h."Description" into v_header
    from public."ExpenseEntryHeader" h where h."ReceiptNo" = v_receipt;
  v_found := found;

  step := 3; check_name := 'Expense is on the portal';
  result := case when v_found then 'ok' else 'FAIL' end;
  detail := case when v_found then coalesce(v_header."Description", '(no description)') else 'No ExpenseEntryHeader row for this receipt - the POS sync has not sent it' end;
  return next;

  -- 4. After the cutover
  step := 4; check_name := 'Dated after the posting start';
  result := case when v_found and v_start is not null and (
                   v_header."Date" > v_start_day
                   or (v_header."Date" = v_start_day and coalesce(v_header."SyncedAtUtc" >= v_start, false)))
                 then 'ok' else 'FAIL' end;
  detail := 'Expense Date ' || coalesce(v_header."Date"::text, '(none)')
    || ', synced ' || coalesce((v_header."SyncedAtUtc" at time zone 'Asia/Manila')::text, '(none)')
    || ' - expenses before the cutover are assumed already counted in the starting stock';
  return next;

  -- 5. Warehouse
  select w."ID" into v_warehouse_id
    from public."Warehouses" w
   where lower(trim(w."Name")) = lower(trim(coalesce(v_header."Warehouse", '')))
   limit 1;

  step := 5; check_name := 'Warehouse matches a portal warehouse';
  result := case when v_warehouse_id is not null then 'ok' else 'FAIL' end;
  detail := 'Expense Warehouse = "' || coalesce(v_header."Warehouse", '(blank)') || '"'
    || case when v_warehouse_id is not null then ' -> ' || v_warehouse_id
            else ' - no Warehouses row with that exact name. Portal names: '
                 || coalesce((select string_agg('"' || w."Name" || '"', ', ' order by w."Name") from public."Warehouses" w), '(none)') end;
  return next;

  -- 6. Last reconcile
  if to_regclass('public."ItemLedgerExpenseSync"') is not null then
    execute 'select "LastError", "ReconciledAtUtc" from public."ItemLedgerExpenseSync" where "ReceiptNo" = $1'
      into v_error, v_reconciled using v_receipt;
    v_sync_found := v_reconciled is not null;
  end if;

  step := 6; check_name := 'Last reconcile did not error';
  result := case when not v_sync_found then 'FAIL' when v_error is not null then 'FAIL' else 'ok' end;
  detail := case
    when not v_sync_found then 'Never reconciled - the trigger did not run for this expense (hook installed after it synced, or not installed)'
    when v_error is not null then 'ERROR: ' || v_error
    else 'Reconciled ' || (v_reconciled at time zone 'Asia/Manila')::text || ', no error' end;
  return next;

  -- 7. What the ledger has
  select count(*), coalesce(sum(e."Quantity"), 0) into v_posted_count, v_posted_qty
    from public."ItemLedgerEntries" e
   where e."DocumentType" = 'POS Expense' and e."DocumentNo" = v_receipt;

  step := 7; check_name := 'Ledger entries posted for this expense';
  result := case when v_posted_count > 0 then 'ok' else 'NONE' end;
  detail := v_posted_count::text || ' entr(ies), net quantity ' || v_posted_qty::text;
  return next;

  -- One row per synced line: does it tie to a stocked item, and if not, the exact reason (the
  -- posting swallows that reason and just skips the line).
  for v_line in
    select l."LineID", l."ItemCode", l."Description", l."Quantity",
           coalesce(v."ItemCode", l."ItemCode") as raw_item,
           nullif(trim(coalesce(l."VariationId", '')), '') as raw_variant
      from public."ExpenseEntryLines" l
      left join public."Variants" v on v."VariationId" = l."VariationId"
     where l."ReceiptNo" = v_receipt
     order by l."LineID"
  loop
    v_n := v_n + 1;
    begin
      if coalesce(v_line."ItemCode", '') = 'INC_EXP' then
        v_reason := 'SKIPPED: INC_EXP = incidental expense, not a stocked item (the POS did not find the item code in its own Items table, or the expense was typed in by hand)';
      elsif nullif(trim(coalesce(v_line.raw_item, '')), '') is null then
        v_reason := 'FAILS: no item code on the line';
      elsif not exists (select 1 from public."Items" i where i."Code" = trim(v_line.raw_item)) then
        v_reason := 'FAILS: item code "' || v_line.raw_item || '" is not in the portal Items';
      elsif coalesce(v_line."Quantity", 0) = 0 then
        v_reason := 'FAILS: quantity is 0';
      else
        select k.item_code, k.variant_id into v_item, v_variant
          from public._ile_resolve_stock_key(v_line.raw_item, v_line.raw_variant) k;
        v_reason := 'OK -> ' || v_item || coalesce(' / variant ' || v_variant, '')
          || case when v_line."Quantity" > 0 then ' (WARNING: quantity is positive, so this ADDS stock)' else '' end;
      end if;
    exception when others then
      v_reason := 'FAILS: ' || sqlerrm;
    end;

    step := 100 + v_n;
    check_name := 'Line: ' || coalesce(v_line."Description", v_line."ItemCode", '?') || ' x' || coalesce(v_line."Quantity", 0)::text;
    result := case when v_reason like 'OK%' then 'ok' when v_reason like 'SKIPPED%' then 'skip' else 'FAIL' end;
    detail := v_reason || ' | line ItemCode=' || coalesce(v_line."ItemCode", '(none)') || ', VariationId=' || coalesce(v_line.raw_variant, '(none)');
    return next;
  end loop;

  if v_n = 0 then
    step := 100; check_name := 'Has synced lines'; result := 'FAIL';
    detail := 'No ExpenseEntryLines rows for this receipt - the header synced but its lines did not';
    return next;
  end if;
end;
$$;

-- VERDICT - one row per check, then one row per line.
select * from pg_temp.ile_expense_diagnose('') order by step;              -- <<< RECEIPT-NO between the quotes (blank = latest)

-- ---------------------------------------------------------------------------
-- (After fixing the cause) post it now - highlight, put in the receipt number, and run on its own.
-- Returns how many ledger entries it wrote, or raises the real error. Safe to run twice: it only
-- ever posts the difference.
-- select public._ile_reconcile_pos_expense('RECEIPT-NO');
