-- RESERVED serials are still ON HAND - companion to supabase_serial_order_reservation.sql.
--
-- A reserved unit is physically on the shelf and still on the Item Ledger (a reservation never touches
-- the ledger), it's just promised to one order. Two places only counted IN_STOCK as "on hand", which
-- would go wrong once reservations exist:
--   * Serial Inventory Journal - Qty. (Serials) left reserved units out, so counting the shelf posted a
--     NEW duplicate serial for every reserved tank (and "Found" on a reserved serial flipped it back In
--     Stock, silently dropping the reservation). Now a reserved serial counts as in stock at its location:
--     it's listed on the line, can be ticked Missing (its reservation comes back if the count is reversed),
--     and can't be added as Found there.
--   * Item Ledger Entries > Reverse on a Production Output - refused when a serial wasn't IN_STOCK, and
--     output built for an order is now RESERVED straight away. RESERVED is accepted too.
--
-- Copies of the latest versions with ONLY the status test widened to ('IN_STOCK', 'RESERVED'):
--   _sij_serials_in_stock, _sij_rows, admin_set_serial_journal_mark, admin_add_serial_journal_found,
--   admin_post_serial_inventory_journal, _ile_on_reversed (supabase_serial_inventory_journal.sql) and
--   admin_get_serial_journal_line_serials (supabase_serial_journal_serials_sku.sql).
-- Don't re-run those two files afterwards (they'd narrow it back to IN_STOCK).
--
-- Run AFTER supabase_serial_order_reservation.sql. Same signatures - create or replace only, no table
-- changes. Safe to re-run.

create or replace function public._sij_serials_in_stock(p_item_code text, p_variant_id text, p_warehouse_id text)
returns int
language sql
stable
security definer
set search_path = public, extensions
as $$
  select count(*)::int
  from public."ItemSerialTracking" s
  join public."Warehouses" w on w."ID" = p_warehouse_id
  where s."ItemCode" = p_item_code
    and (p_variant_id is null or s."VariantCode" = p_variant_id)
    and s."Status" in ('IN_STOCK', 'RESERVED')
    and public._sij_same_location(s."Location", w."Name");
$$;

revoke execute on function public._sij_serials_in_stock(text, text, text) from public, anon, authenticated;

-- The worksheet, with live figures. missing_count / found_count only count marks that are still
-- valid (a Missing serial still in stock here, a Found serial still NOT in stock here).

create or replace function public._sij_rows(p_batch_name text)
returns table(
  line_id bigint, item_code text, item_name text, variant_id text, variant_name text, sku text,
  warehouse_id text, warehouse_name text,
  qty_calculated numeric, qty_counted int, qty_serials int, qty_ledger numeric,
  missing_count int, found_count int, new_count int, serial_quantity int, ledger_quantity numeric,
  updated_at_utc timestamptz, updated_by text
)
language sql
stable
security definer
set search_path = public, extensions
as $$
  with base as (
    select l.*, w."Name" as wh_name,
           public._sij_serials_in_stock(l."ItemCode", l."VariantId", l."WarehouseId") as serials,
           public._ile_balance(l."ItemCode", l."VariantId", l."WarehouseId") as ledger,
           (select count(*)::int from public."SerialJournalLineSerials" m
              join public."ItemSerialTracking" s on s."RunningSerialNo" = m."RunningSerialNo"
              where m."LineID" = l."LineID" and m."Mark" = 'MISSING'
                and s."Status" in ('IN_STOCK', 'RESERVED') and public._sij_same_location(s."Location", w."Name")) as missing,
           (select count(*)::int from public."SerialJournalLineSerials" m
              join public."ItemSerialTracking" s on s."RunningSerialNo" = m."RunningSerialNo"
              where m."LineID" = l."LineID" and m."Mark" = 'FOUND'
                and not (s."Status" in ('IN_STOCK', 'RESERVED') and public._sij_same_location(s."Location", w."Name"))) as found
    from public."SerialJournalLines" l
    left join public."Warehouses" w on w."ID" = l."WarehouseId"
    where l."BatchName" = p_batch_name
  )
  select
    b."LineID", b."ItemCode"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), b."ItemCode")::text,
    b."VariantId"::text, v."VariantName"::text,
    coalesce(nullif(v."SKU", ''),
      (select nullif(vf."SKU", '') from public."Variants" vf
        where vf."ItemCode" = b."ItemCode" and nullif(vf."SKU", '') is not null
        order by vf."SyncedAtUtc" desc nulls last limit 1),
      nullif(i."SKU", ''))::text,
    b."WarehouseId"::text, coalesce(b.wh_name, b."WarehouseId")::text,
    b."QtyCalculated", b."QtyCounted", b.serials, b.ledger,
    b.missing, b.found,
    case when b."QtyCounted" is null then null else b."QtyCounted" - b.serials + b.missing - b.found end,
    case when b."QtyCounted" is null then null else b."QtyCounted" - b.serials end,
    case when b."QtyCounted" is null then null else b."QtyCounted" - b.ledger end,
    b."UpdatedAtUtc", b."UpdatedBy"::text
  from base b
  left join public."Items" i on i."Code" = b."ItemCode"
  left join public."Variants" v on v."VariationId" = coalesce(b."VariantId", i."VariationId")
$$;

revoke execute on function public._sij_rows(text) from public, anon, authenticated;

create or replace function public.admin_get_serial_journal_line_serials(
  p_admin_username text,
  p_admin_password text,
  p_line_id bigint
)
returns table(
  running_serial_no bigint, serial_no text, item_code text, variant_code text, status text, location text,
  source_document_no text, created_at_utc timestamptz, mark text, in_stock_here boolean, variant_sku text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line public."SerialJournalLines";
  v_wh_name text;
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_line from public."SerialJournalLines" where "LineID" = p_line_id;
  if not found then
    raise exception 'That line is no longer on the worksheet. Refresh the page.';
  end if;
  select "Name" into v_wh_name from public."Warehouses" where "ID" = v_line."WarehouseId";

  return query
    select s."RunningSerialNo", s."SerialNo"::text, s."ItemCode"::text, s."VariantCode"::text,
           s."Status"::text, s."Location"::text, s."SourceDocumentNo"::text, s."CreatedAtUtc",
           m."Mark"::text,
           (s."Status" in ('IN_STOCK', 'RESERVED') and public._sij_same_location(s."Location", v_wh_name)),
           nullif(trim(v."SKU"), '')::text
    from public."ItemSerialTracking" s
    left join public."SerialJournalLineSerials" m on m."LineID" = p_line_id and m."RunningSerialNo" = s."RunningSerialNo"
    left join public."Variants" v on v."VariationId" = s."VariantCode"
    where (s."Status" in ('IN_STOCK', 'RESERVED') and public._sij_same_location(s."Location", v_wh_name)
           and s."ItemCode" = v_line."ItemCode"
           and (v_line."VariantId" is null or s."VariantCode" = v_line."VariantId"))
       or m."Mark" is not null
    order by (m."Mark" = 'FOUND') nulls first, s."SerialNo";
end;
$$;

grant execute on function public.admin_get_serial_journal_line_serials(text, text, bigint) to anon;

-- p_mark: 'MISSING' or null (clear). Only for a serial in stock at the line's location.
create or replace function public.admin_set_serial_journal_mark(
  p_admin_username text,
  p_admin_password text,
  p_line_id bigint,
  p_running_serial_no bigint,
  p_mark text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line public."SerialJournalLines";
  v_serial public."ItemSerialTracking";
  v_wh_name text;
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_line from public."SerialJournalLines" where "LineID" = p_line_id;
  if not found then
    raise exception 'That line is no longer on the worksheet. Refresh the page.';
  end if;

  if p_mark is null or trim(p_mark) = '' then
    delete from public."SerialJournalLineSerials" where "LineID" = p_line_id and "RunningSerialNo" = p_running_serial_no;
    return;
  end if;
  if upper(trim(p_mark)) <> 'MISSING' then
    raise exception 'Unknown mark "%".', p_mark;
  end if;

  select "Name" into v_wh_name from public."Warehouses" where "ID" = v_line."WarehouseId";
  select * into v_serial from public."ItemSerialTracking" where "RunningSerialNo" = p_running_serial_no;
  if not found or not public._sij_serial_matches(v_serial, v_line."ItemCode", v_line."VariantId")
     or v_serial."Status" not in ('IN_STOCK', 'RESERVED') or not public._sij_same_location(v_serial."Location", v_wh_name) then
    raise exception 'That serial is not in stock at % for this line any more. Refresh.', coalesce(v_wh_name, 'this location');
  end if;

  insert into public."SerialJournalLineSerials" ("LineID", "RunningSerialNo", "Mark", "MarkedBy")
  values (p_line_id, p_running_serial_no, 'MISSING', p_admin_username)
  on conflict ("LineID", "RunningSerialNo") do update set "Mark" = 'MISSING', "MarkedAtUtc" = now(), "MarkedBy" = excluded."MarkedBy";

  update public."SerialJournalLines" set "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username where "LineID" = p_line_id;
end;
$$;

-- A labelled unit on the shelf that the system doesn't have in stock here. Must be this line's item
-- (and variant, when the serial has one).
create or replace function public.admin_add_serial_journal_found(
  p_admin_username text,
  p_admin_password text,
  p_line_id bigint,
  p_serial_no text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line public."SerialJournalLines";
  v_serial public."ItemSerialTracking";
  v_wh_name text;
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_line from public."SerialJournalLines" where "LineID" = p_line_id;
  if not found then
    raise exception 'That line is no longer on the worksheet. Refresh the page.';
  end if;
  select "Name" into v_wh_name from public."Warehouses" where "ID" = v_line."WarehouseId";

  select * into v_serial from public."ItemSerialTracking" where upper("SerialNo") = upper(trim(coalesce(p_serial_no, '')));
  if not found then
    raise exception 'Serial "%" does not exist. A unit with no serial yet is covered by the count itself - Post creates a new serial for it.', trim(coalesce(p_serial_no, ''));
  end if;
  if v_serial."ItemCode" <> v_line."ItemCode"
     or (v_line."VariantId" is not null and v_serial."VariantCode" is not null and v_serial."VariantCode" <> v_line."VariantId") then
    raise exception 'Serial % is item % % - not this line''s item. Add it on that item''s line.',
      v_serial."SerialNo", v_serial."ItemCode", coalesce('(' || v_serial."VariantCode" || ')', '');
  end if;
  if v_serial."Status" in ('IN_STOCK', 'RESERVED') and public._sij_same_location(v_serial."Location", v_wh_name) then
    raise exception 'Serial % is already in stock at % - it''s on the list already.', v_serial."SerialNo", v_wh_name;
  end if;

  insert into public."SerialJournalLineSerials" ("LineID", "RunningSerialNo", "Mark", "MarkedBy")
  values (p_line_id, v_serial."RunningSerialNo", 'FOUND', p_admin_username)
  on conflict ("LineID", "RunningSerialNo") do update set "Mark" = 'FOUND', "MarkedAtUtc" = now(), "MarkedBy" = excluded."MarkedBy";

  update public."SerialJournalLines" set "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username where "LineID" = p_line_id;
end;
$$;

-- Dry run: every counted line with what it would post, and a problem text (null = fine). Real run:
-- all-or-nothing; any problem line stops the whole post.
create or replace function public.admin_post_serial_inventory_journal(
  p_admin_username text,
  p_admin_password text,
  p_batch_name text,
  p_posting_date date,
  p_reason text default null,
  p_dry_run boolean default true
)
returns table(
  line_id bigint, item_code text, item_name text, variant_name text, warehouse_name text,
  qty_counted int, qty_serials int, qty_ledger numeric,
  missing_count int, found_count int, new_count int, ledger_quantity numeric,
  problem text, document_no text, new_serial_nos text[]
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_batch text := trim(coalesce(p_batch_name, 'DEFAULT'));
  v_dry boolean := coalesce(p_dry_run, true);
  v_transaction_no bigint;
  v_doc_no text;
  v_row record;
  v_wh_name text;
  v_serial record;
  v_serial_variant text;
  v_serial_desc text;
  v_serial_no text;
  v_running bigint;
  v_new text[];
  v_problem text;
  v_ids bigint[] := array[]::bigint[];
  i int;
begin
  if not public.is_phys_journal_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if not exists (select 1 from public."SerialJournalLines" where "BatchName" = v_batch and "QtyCounted" is not null) then
    raise exception 'Nothing on this worksheet has a count yet.';
  end if;
  if not v_dry and (p_reason is null or trim(p_reason) = '') then
    raise exception 'A reason is required (e.g. "Cycle count", "Serial count").';
  end if;

  if not v_dry then
    v_transaction_no := nextval('public.ile_transaction_no_seq');
    v_doc_no := 'SPHYS-' || lpad(v_transaction_no::text, 6, '0');
    -- Same lock Post Output / a ledger post takes per stock key is taken per line below; this one
    -- just stops two people posting the same batch at once.
    perform pg_advisory_xact_lock(hashtext('sij|' || v_batch));
  end if;

  for v_row in
    select * from public._sij_rows(v_batch) r where r.qty_counted is not null order by r.item_name, r.variant_name nulls first
  loop
    v_problem := null;
    v_new := '{}';

    if v_row.new_count < 0 then
      v_problem := format('Counted %s but %s serial(s) are in stock here (%s ticked Missing, %s Found) - tick %s more as Missing on Serial Nos.',
        v_row.qty_counted, v_row.qty_serials, v_row.missing_count, v_row.found_count, -v_row.new_count);
    end if;

    if not v_dry then
      if v_problem is not null then
        raise exception '% %: %', v_row.item_code, coalesce('(' || v_row.variant_name || ')', ''), v_problem;
      end if;

      perform pg_advisory_xact_lock(hashtext(v_row.item_code || '|' || coalesce(v_row.variant_id, '') || '|' || v_row.warehouse_id));
      v_wh_name := v_row.warehouse_name;

      -- Missing -> MISSING
      for v_serial in
        select s.* from public."SerialJournalLineSerials" m
        join public."ItemSerialTracking" s on s."RunningSerialNo" = m."RunningSerialNo"
        where m."LineID" = v_row.line_id and m."Mark" = 'MISSING'
          and s."Status" in ('IN_STOCK', 'RESERVED') and public._sij_same_location(s."Location", v_wh_name)
        for update of s
      loop
        insert into public."SerialJournalPostedSerials"
          ("TransactionNo", "DocumentNo", "ItemCode", "VariantId", "WarehouseId", "RunningSerialNo", "Action", "PrevStatus", "PrevLocation", "PostedBy")
        values (v_transaction_no, v_doc_no, v_row.item_code, v_row.variant_id, v_row.warehouse_id, v_serial."RunningSerialNo", 'MISSING', v_serial."Status", v_serial."Location", p_admin_username);
        update public."ItemSerialTracking"
          set "Status" = 'MISSING', "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
          where "RunningSerialNo" = v_serial."RunningSerialNo";
      end loop;

      -- Found -> IN_STOCK here
      for v_serial in
        select s.* from public."SerialJournalLineSerials" m
        join public."ItemSerialTracking" s on s."RunningSerialNo" = m."RunningSerialNo"
        where m."LineID" = v_row.line_id and m."Mark" = 'FOUND'
          and not (s."Status" in ('IN_STOCK', 'RESERVED') and public._sij_same_location(s."Location", v_wh_name))
        for update of s
      loop
        insert into public."SerialJournalPostedSerials"
          ("TransactionNo", "DocumentNo", "ItemCode", "VariantId", "WarehouseId", "RunningSerialNo", "Action", "PrevStatus", "PrevLocation", "PostedBy")
        values (v_transaction_no, v_doc_no, v_row.item_code, v_row.variant_id, v_row.warehouse_id, v_serial."RunningSerialNo", 'FOUND', v_serial."Status", v_serial."Location", p_admin_username);
        update public."ItemSerialTracking"
          set "Status" = 'IN_STOCK', "Location" = v_wh_name,
              "VariantCode" = coalesce("VariantCode", v_row.variant_id),
              "UpdatedAtUtc" = now(), "UpdatedBy" = p_admin_username
          where "RunningSerialNo" = v_serial."RunningSerialNo";
      end loop;

      -- New serials for the units that have none
      if v_row.new_count > 0 then
        v_serial_variant := coalesce(v_row.variant_id,
          (select min(v."VariationId") from public."Variants" v where v."ItemCode" = v_row.item_code having count(*) = 1));
        v_serial_desc := left(coalesce(v_row.item_name, v_row.item_code), 255);
        for i in 1 .. v_row.new_count loop
          v_serial_no := public._production_next_serial_no(v_row.item_code);
          insert into public."ItemSerialTracking"
            ("SerialNo", "ItemCode", "ItemDescription", "Location", "Status", "SourceDocumentNo", "CreatedBy", "VariantCode", "UpdatedAtUtc", "UpdatedBy")
          values (v_serial_no, v_row.item_code, v_serial_desc, v_wh_name, 'IN_STOCK', v_doc_no, p_admin_username, v_serial_variant, now(), p_admin_username)
          returning "RunningSerialNo" into v_running;
          insert into public."SerialJournalPostedSerials"
            ("TransactionNo", "DocumentNo", "ItemCode", "VariantId", "WarehouseId", "RunningSerialNo", "Action", "PostedBy")
          values (v_transaction_no, v_doc_no, v_row.item_code, v_row.variant_id, v_row.warehouse_id, v_running, 'NEW', p_admin_username);
          v_new := v_new || v_serial_no;
        end loop;
      end if;

      -- Ledger to the count
      if coalesce(v_row.ledger_quantity, 0) <> 0 then
        perform public._ile_post(
          case when v_row.ledger_quantity > 0 then 'Positive Adjmt.' else 'Negative Adjmt.' end,
          v_row.item_code, v_row.variant_id, v_row.warehouse_id, v_row.ledger_quantity,
          coalesce(p_posting_date, public._ile_today()), 'Serial Phys. Inventory', v_doc_no, trim(p_reason),
          v_transaction_no, p_admin_username
        );
      end if;

      v_ids := v_ids || v_row.line_id;
    end if;

    line_id := v_row.line_id; item_code := v_row.item_code; item_name := v_row.item_name;
    variant_name := v_row.variant_name; warehouse_name := v_row.warehouse_name;
    qty_counted := v_row.qty_counted; qty_serials := v_row.qty_serials; qty_ledger := v_row.qty_ledger;
    missing_count := v_row.missing_count; found_count := v_row.found_count; new_count := v_row.new_count;
    ledger_quantity := v_row.ledger_quantity; problem := v_problem; document_no := v_doc_no; new_serial_nos := v_new;
    return next;
  end loop;

  if not v_dry and array_length(v_ids, 1) > 0 then
    delete from public."SerialJournalLines" where "LineID" = any(v_ids);
  end if;
end;
$$;

grant execute on function public.admin_set_serial_journal_mark(text, text, bigint, bigint, text) to anon;
grant execute on function public.admin_add_serial_journal_found(text, text, bigint, text) to anon;
grant execute on function public.admin_post_serial_inventory_journal(text, text, text, date, text, boolean) to anon;

-- Copied from supabase_production_orders.sql unchanged, plus the 'Serial Phys. Inventory' branch at
-- the end: the first reversed entry of a SPHYS transaction undoes ALL of that transaction's serial
-- changes (later entries of the same transaction find nothing left to undo).
create or replace function public._ile_on_reversed(p_entry public."ItemLedgerEntries")
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line record;
  v_key record;
  v_left numeric;
  v_take numeric;
  v_output public."ProductionOrderOutputs";
  v_warehouse_name text;
  v_bad record;
  v_ps record;
begin
  if p_entry."DocumentType" in ('Transfer Shipment', 'Transfer Receipt') then
    raise exception 'Transfer entries cannot be reversed here - the transfer document would still say the goods moved. Correct the stock with an adjustment instead.';
  end if;

  -- Sales follow their order automatically (supabase_item_ledger_sales.sql): a hand-made reversal
  -- would be undone on the next pass, since the order would still say the item was sold.
  if p_entry."DocumentType" = 'Sales Order' then
    raise exception 'Sales entries follow their order automatically - cancel or edit the order, or post an adjustment.';
  end if;

  if p_entry."DocumentType" = 'Purchase Receipt' and p_entry."Quantity" > 0 then
    v_left := p_entry."Quantity";

    for v_line in
      select "EntryNo", "ItemCode", "VariantCode", "QtyReceived"
      from public."PurchaseOrderLines"
      where "PONo" = p_entry."DocumentNo"
        and "WarehouseId" = p_entry."WarehouseId"
        and "QtyReceived" > 0
      order by "EntryNo"
    loop
      exit when v_left <= 0;

      begin
        select k.item_code, k.variant_id into v_key
          from public._ile_resolve_stock_key(v_line."ItemCode", nullif(trim(coalesce(v_line."VariantCode", '')), '')) k;
      exception when others then
        continue;
      end;

      if v_key.item_code = p_entry."ItemCode" and coalesce(v_key.variant_id, '') = coalesce(p_entry."VariantId", '') then
        v_take := least(v_left, v_line."QtyReceived");
        update public."PurchaseOrderLines" set "QtyReceived" = "QtyReceived" - v_take where "EntryNo" = v_line."EntryNo";
        v_left := v_left - v_take;
      end if;
    end loop;
  end if;

  -- Production output (supabase_production_orders.sql).
  if p_entry."DocumentType" = 'Production Output' and p_entry."Quantity" > 0 then
    select * into v_output from public."ProductionOrderOutputs" where "EntryNo" = p_entry."EntryNo";
    if found then
      select "Name" into v_warehouse_name from public."Warehouses" where "ID" = p_entry."WarehouseId";

      select s."SerialNo", s."Status", s."Location" into v_bad
        from public."ProductionOrderOutputSerials" os
        join public."ItemSerialTracking" s on s."RunningSerialNo" = os."RunningSerialNo"
        where os."EntryNo" = p_entry."EntryNo"
          and (s."Status" not in ('IN_STOCK', 'RESERVED') or coalesce(s."Location", '') <> coalesce(v_warehouse_name, ''))
        limit 1;
      if found then
        raise exception 'Serial % from this output is already % at % - it can''t be reversed. Correct the stock with an adjustment instead.',
          v_bad."SerialNo", v_bad."Status", coalesce(v_bad."Location", '(no location)');
      end if;

      update public."ItemSerialTracking" s
        set "Status" = 'REVERSED', "UpdatedAtUtc" = now()
        from public."ProductionOrderOutputSerials" os
        where os."EntryNo" = p_entry."EntryNo" and s."RunningSerialNo" = os."RunningSerialNo";

      update public."ProductionOrderLines"
        set "QtyOutput" = greatest(0, "QtyOutput" - v_output."Quantity")
        where "LineNo" = v_output."LineNo";

      update public."ProductionOrders"
        set "Status" = 'Released', "FinishedAtUtc" = null, "UpdatedAtUtc" = now()
        where "No" = v_output."ProdOrderNo" and "Status" = 'Finished';
    end if;
  end if;

  -- Serial Inventory Journal (supabase_serial_inventory_journal.sql).
  if p_entry."DocumentType" = 'Serial Phys. Inventory' then
    for v_ps in
      select ps.*, s."Status" as cur_status, s."Location" as cur_location, s."SerialNo" as serial_no, w."Name" as wh_name
      from public."SerialJournalPostedSerials" ps
      join public."ItemSerialTracking" s on s."RunningSerialNo" = ps."RunningSerialNo"
      left join public."Warehouses" w on w."ID" = ps."WarehouseId"
      where ps."TransactionNo" = p_entry."TransactionNo" and ps."UndoneAtUtc" is null
      order by ps."Id"
      for update of ps, s
    loop
      if v_ps."Action" in ('NEW', 'FOUND') then
        if v_ps.cur_status not in ('IN_STOCK', 'RESERVED') or not public._sij_same_location(v_ps.cur_location, v_ps.wh_name) then
          raise exception 'Serial % from this count is already % at % - it can''t be reversed. Count again instead.',
            v_ps.serial_no, v_ps.cur_status, coalesce(v_ps.cur_location, '(no location)');
        end if;
      elsif v_ps.cur_status <> 'MISSING' then
        raise exception 'Serial % (marked Missing by this count) is now % - it can''t be reversed. Count again instead.',
          v_ps.serial_no, v_ps.cur_status;
      end if;

      update public."ItemSerialTracking"
        set "Status" = case when v_ps."Action" = 'NEW' then 'REVERSED' else v_ps."PrevStatus" end,
            "Location" = case when v_ps."Action" = 'NEW' then "Location" else v_ps."PrevLocation" end,
            "UpdatedAtUtc" = now()
        where "RunningSerialNo" = v_ps."RunningSerialNo";
      update public."SerialJournalPostedSerials" set "UndoneAtUtc" = now() where "Id" = v_ps."Id";
    end loop;
  end if;
end;
$$;

revoke execute on function public._ile_on_reversed(public."ItemLedgerEntries") from public, anon, authenticated;

notify pgrst, 'reload schema';

-- Verification - one result: each function and whether its body now accepts RESERVED.
select p.proname::text as function_name,
       pg_get_functiondef(p.oid) like '%''RESERVED''%' as counts_reserved_as_on_hand
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('_sij_serials_in_stock', '_sij_rows', 'admin_get_serial_journal_line_serials',
                    'admin_set_serial_journal_mark', 'admin_add_serial_journal_found',
                    'admin_post_serial_inventory_journal', '_ile_on_reversed')
order by 1;
