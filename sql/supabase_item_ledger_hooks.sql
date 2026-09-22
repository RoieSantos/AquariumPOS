-- Item Ledger Entries - makes the PORTAL the owner of inventory, per "my goal here is to remove the
-- hook of relying the inventory in the pancake system. we are building our own inventory system
-- through our portal".
--
-- Run AFTER supabase_item_ledger_entries.sql, and BEFORE deploying the matching JS
-- (purchaseOrders.js, transferOrders.js, stockOnHand.js). Then load your starting stock with a
-- stock count upload on the Item Ledger Entries page (supabase_item_ledger_stock_count.sql).
--
-- WHAT CHANGED FROM "LEDGER NEXT TO PANCAKE"
-- An earlier version of this file kept every Pancake push and gate in place and just wrote the
-- ledger beside them. This replaces that: Pancake is no longer called for inventory at all.
--   Purchase Order receive -> Purchase entry in the ledger. No Pancake stock-in, no sync status.
--   Transfer Order ship    -> Transfer entry, minus at the From warehouse. Refused if the From
--                             warehouse doesn't have the stock (the check Pancake used to make).
--   Transfer Order receive -> Transfer entry, plus at the To warehouse.
--   Stock On Hand          -> computed from the ledger, not from a Pancake snapshot.
-- Everything is one database transaction: the document update and its ledger entry commit or fail
-- together, so the old "Pancake accepted it but the portal didn't" states no longer exist - and
-- neither do the Failed/Rejected/retry/verify-in-Pancake workarounds built around them.
--
-- Sales are handled separately, in supabase_item_ledger_sales.sql.

-- ============================================================================
-- 0. Remove the previous design's leftovers (all safe if they were never created)
-- ============================================================================

drop function if exists public._ile_post_safe(text, text, text, text, numeric, date, text, text, text, bigint, text);
drop function if exists public.admin_list_item_ledger_posting_failures(text, text);
drop function if exists public.admin_dismiss_item_ledger_posting_failure(text, text, bigint);
drop table if exists public."ItemLedgerPostingFailures";

-- Existed only to mark a PO received without a Pancake call after a Pancake sync failed. With no
-- Pancake sync there is nothing for it to bypass, and it was an un-audited way to move QtyReceived.
drop function if exists public.staff_confirm_purchase_order_receipt_without_sync(text, text, text, jsonb, text);

-- ============================================================================
-- 1. Purchase Order receiving
-- ============================================================================

-- Same name and inputs as before, so the Receive button's call shape is unchanged; what comes back
-- is now one row per line received. PurchaseOrderLines.Quantity is in BASE units (the typed
-- ordering-unit quantity lives in QuantityUom), so the increment goes into the ledger as-is - a PO
-- in BOX lands as pieces.
--
-- Receives against the line's own variant. A line for an item that has several variants and no
-- variant picked is refused with a clear message (fix the line's variant, then receive) rather than
-- guessing which one arrived - guessing is how one variant's stock ends up on another's shelf.
drop function if exists public.staff_receive_purchase_order_lines(text, text, text, jsonb);

create or replace function public.staff_receive_purchase_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_lines jsonb
)
returns table(entry_no bigint, item_code text, quantity_received numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_line jsonb;
  v_entry_no bigint;
  v_requested numeric;
  v_po_line record;
  v_increment numeric;
  v_transaction_no bigint;
  v_received_count int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if not exists (select 1 from public."PurchaseOrders" where "PONo" = p_po_no) then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one line with a quantity is required.';
  end if;

  -- One transaction number for the whole click, so a Reverse undoes everything received together.
  v_transaction_no := nextval('public.ile_transaction_no_seq');

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_entry_no := nullif(v_line ->> 'entry_no', '')::bigint;
    v_requested := nullif(v_line ->> 'quantity', '')::numeric;
    if v_entry_no is null or v_requested is null or v_requested <= 0 then
      continue;
    end if;

    select * into v_po_line from public."PurchaseOrderLines" where "EntryNo" = v_entry_no and "PONo" = p_po_no;
    if not found then
      continue;
    end if;

    -- Running-total rule, unchanged: never receive more than is still outstanding on the line.
    v_increment := least(v_requested, greatest(0, v_po_line."Quantity" - v_po_line."QtyReceived"));
    if v_increment <= 0 then
      continue;
    end if;

    if v_po_line."WarehouseId" is null or trim(v_po_line."WarehouseId") = '' then
      raise exception 'Item "%" has no Warehouse on this line - set one before receiving.', v_po_line."ItemCode";
    end if;

    perform public._ile_post(
      'Purchase',
      v_po_line."ItemCode",
      nullif(trim(coalesce(v_po_line."VariantCode", '')), ''),
      v_po_line."WarehouseId",
      v_increment,
      public._ile_today(),
      'Purchase Receipt',
      p_po_no,
      'Received against ' || p_po_no,
      v_transaction_no,
      p_admin_username
    );

    update public."PurchaseOrderLines"
       set "QtyReceived" = least("Quantity", "QtyReceived" + v_increment)
     where "EntryNo" = v_entry_no;

    v_received_count := v_received_count + 1;
    entry_no := v_entry_no;
    item_code := v_po_line."ItemCode";
    quantity_received := v_increment;
    return next;
  end loop;

  if v_received_count = 0 then
    raise exception 'No matching line(s) with a quantity greater than zero remain to be received.';
  end if;
end;
$$;

grant execute on function public.staff_receive_purchase_order_lines(text, text, text, jsonb) to anon;

-- ============================================================================
-- 2. Reversing an entry must not leave its document disagreeing with the ledger
-- ============================================================================

-- Called by admin_reverse_item_ledger_transaction for each entry it cancels (see the stub in
-- supabase_item_ledger_entries.sql).
--   * A Purchase Receipt gives its quantity back to the PO line(s) it came from, so a mistyped
--     receipt can be undone AND received again correctly. Lines are matched by PO, warehouse and
--     resolved stock key (the same item+variant normalisation the ledger itself uses). If the PO
--     has since been posted or deleted there is nothing left to hand back and that is fine.
--   * A Transfer entry cannot be reversed here: the transfer's own Qty Shipped/Received would keep
--     saying the goods moved, and changing them would re-trigger the ledger. Correct a transfer's
--     stock with an adjustment instead.
--   * A Sales Order entry cannot be reversed here either: it is kept in line with its order
--     automatically, so a hand-made reversal would just be re-posted.
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
end;
$$;

revoke execute on function public._ile_on_reversed(public."ItemLedgerEntries") from public, anon, authenticated;

-- ============================================================================
-- 3. Transfer Orders
-- ============================================================================

-- Who performed the Ship/Receive - written by docs/js/transferOrders.js in the same update as the
-- quantity, so the trigger below can credit the ledger entry to them. Portal-only, like Qty To Ship
-- / Qty Shipped.
alter table public."Transfer_Line" add column if not exists "Last Actor" varchar(100);

-- Mirrors Business Central's transfer: SHIP takes stock out of the From warehouse (it is now in
-- transit, so on nobody's shelf), RECEIVE puts it into the To warehouse.
--
-- Fires on the running totals ("Qty Shipped" / "Qty Received" are cumulative), so it posts the
-- DELTA - a partial shipment posts just that shipment, and re-saving the same total posts nothing.
--
-- A shipment the From warehouse can't cover is REFUSED (p_prevent_negative), which fails the
-- Transfer_Line update itself - so nothing is recorded as shipped. This is the check Pancake used
-- to make ("not enough stock at the source warehouse").
--
-- Receive legs are only posted for lines the portal actually shipped ("Qty Shipped" > 0). Qty
-- Received also exists on the desktop's own transfers (same table, synced up), which never carry
-- "Qty Shipped" - those are not this ledger's business.
create or replace function public._ile_transfer_line_post()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ship_delta numeric;
  v_recv_delta numeric;
  v_header record;
  v_actor text := coalesce(nullif(trim(coalesce(new."Last Actor", '')), ''), 'system');
  v_variant text := nullif(trim(coalesce(new."Variant ID", '')), '');
begin
  v_ship_delta := coalesce(new."Qty Shipped", 0) - case when tg_op = 'UPDATE' then coalesce(old."Qty Shipped", 0) else 0 end;
  v_recv_delta := coalesce(new."Qty Received", 0) - case when tg_op = 'UPDATE' then coalesce(old."Qty Received", 0) else 0 end;

  if coalesce(new."Qty Shipped", 0) <= 0 then
    v_recv_delta := 0;
  end if;

  if v_ship_delta = 0 and v_recv_delta = 0 then
    return new;
  end if;

  select "From Warehouse ID" as from_id, "From Warehouse" as from_name,
         "To Warehouse ID" as to_id, "To Warehouse" as to_name
    into v_header
    from public."Transfer_Header" where "No." = new."Document No.";

  if v_ship_delta <> 0 then
    perform public._ile_post(
      'Transfer', new."Item No.", v_variant, coalesce(v_header.from_id, ''), -v_ship_delta,
      public._ile_today(), 'Transfer Shipment', new."Document No.",
      'Shipped to ' || coalesce(v_header.to_name, v_header.to_id, '?'), null, v_actor,
      null, true
    );
  end if;

  if v_recv_delta <> 0 then
    perform public._ile_post(
      'Transfer', new."Item No.", v_variant, coalesce(v_header.to_id, ''), v_recv_delta,
      public._ile_today(), 'Transfer Receipt', new."Document No.",
      'Received from ' || coalesce(v_header.from_name, v_header.from_id, '?'), null, v_actor
    );
  end if;

  return new;
end;
$$;

drop trigger if exists "TR_Transfer_Line_ItemLedger" on public."Transfer_Line";
create trigger "TR_Transfer_Line_ItemLedger"
  after insert or update of "Qty Shipped", "Qty Received" on public."Transfer_Line"
  for each row execute function public._ile_transfer_line_post();

drop function if exists public.staff_get_transfer_line_stock(text, text, text);

-- The Manage modal's "Available" column and the pre-ship check: what the From warehouse has on
-- hand, per line, from the ledger. A line that can't be resolved (e.g. an item with several
-- variants and none picked) comes back with fetch_error instead of a number.
create or replace function public.staff_get_transfer_line_stock(
  p_admin_username text,
  p_admin_password text,
  p_document_no text
)
returns table(line_no bigint, available_quantity numeric, fetch_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_from text;
  v_line record;
  v_key record;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select "From Warehouse ID" into v_from from public."Transfer_Header" where "No." = p_document_no;

  for v_line in
    select tl."Line No."::bigint as ln, tl."Item No."::text as item_no, tl."Variant ID"::text as variant_id
    from public."Transfer_Line" tl
    where tl."Document No." = p_document_no
    order by tl."Line No."
  loop
    line_no := v_line.ln;
    available_quantity := null;
    fetch_error := null;

    begin
      select k.item_code, k.variant_id into v_key
        from public._ile_resolve_stock_key(v_line.item_no, nullif(trim(coalesce(v_line.variant_id, '')), '')) k;
      available_quantity := public._ile_balance(v_key.item_code, v_key.variant_id, coalesce(v_from, ''));
    exception when others then
      fetch_error := sqlerrm;
    end;

    return next;
  end loop;
end;
$$;

grant execute on function public.staff_get_transfer_line_stock(text, text, text) to anon;

-- ============================================================================
-- 4. Stock On Hand - now computed from the ledger
-- ============================================================================

-- Same name, inputs and columns as the Pancake-snapshot version, so the page and its print view
-- keep working; only the source changed. last_refreshed_at_utc is now the time of the most recent
-- ledger movement (there is nothing to "refresh" any more - it is always current).
--
-- EVERY active item appears. Item/variant/warehouse combinations with ledger entries show their
-- balance; an active item with nothing posted shows as 0 - in the selected warehouse, or with no
-- warehouse when none is selected - so "nothing in stock" is visible rather than the item silently
-- missing. There is no category scoping: the old "Include in Stock Sync" flag existed only to
-- limit a Pancake pull, and the portal now tracks everything.
drop function if exists public.staff_list_item_warehouse_stock(text, text, text, text, text, text);

create or replace function public.staff_list_item_warehouse_stock(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text default null,
  p_search text default null,
  p_category_code text default null,
  p_vendor_code text default null
)
returns table(
  item_code text,
  item_name text,
  variant_name text,
  category_code text,
  category_name text,
  vendor_code text,
  vendor_name text,
  warehouse_id text,
  warehouse_name text,
  remain_quantity numeric,
  last_refreshed_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    with stock as (
      select e."ItemCode"::text as s_item, e."VariantId"::text as s_variant, e."WarehouseId"::text as s_warehouse, sum(e."Quantity") as s_qty
      from public."ItemLedgerEntries" e
      where p_warehouse_id is null or trim(p_warehouse_id) = '' or e."WarehouseId" = p_warehouse_id
      group by e."ItemCode", e."VariantId", e."WarehouseId"
      union all
      select i."Code"::text, null::text,
             case when nullif(trim(coalesce(p_warehouse_id, '')), '') is not null then p_warehouse_id else null end,
             0::numeric
      from public."Items" i
      where coalesce(i."IsActive", true)
        and not exists (
          select 1 from public."ItemLedgerEntries" e
          where e."ItemCode" = i."Code"
            and (p_warehouse_id is null or trim(p_warehouse_id) = '' or e."WarehouseId" = p_warehouse_id)
        )
    )
    select
      s.s_item::text,
      coalesce(nullif(trim(itm."Name"), ''), nullif(trim(itm."Description"), ''), s.s_item)::text,
      nullif(trim(v."VariantName"), '')::text,
      itm."CategoryCode"::text,
      coalesce(cat."Description", itm."CategoryCode")::text,
      itm."VendorCode"::text,
      vend."Name"::text,
      s.s_warehouse::text,
      coalesce(w."Name", s.s_warehouse, '-')::text,
      s.s_qty,
      (select max(x."PostedAtUtc") from public."ItemLedgerEntries" x)
    from stock s
    left join public."Items" itm on itm."Code" = s.s_item
    left join public."Variants" v on v."VariationId" = s.s_variant
    left join public."Warehouses" w on w."ID" = s.s_warehouse
    left join public."Categories" cat on cat."Code" = itm."CategoryCode"
    left join public."Vendors" vend on vend."VendorCode" = itm."VendorCode"
    where (p_category_code is null or trim(p_category_code) = '' or itm."CategoryCode" = p_category_code)
      and (p_vendor_code is null or trim(p_vendor_code) = '' or itm."VendorCode" = p_vendor_code)
      and (
        p_search is null or trim(p_search) = ''
        or s.s_item ilike '%' || trim(p_search) || '%'
        or itm."Name" ilike '%' || trim(p_search) || '%'
        or v."VariantName" ilike '%' || trim(p_search) || '%'
      )
    order by coalesce(nullif(trim(itm."Name"), ''), s.s_item), 2, 9;
end;
$$;

grant execute on function public.staff_list_item_warehouse_stock(text, text, text, text, text, text) to anon;

drop function if exists public.staff_list_stock_sync_categories(text, text);

-- The Category filter's options: every category in use on an item (it used to be only the ones
-- flagged "Include in Stock Sync", a Pancake-pull setting that no longer exists). Name kept so the
-- page needs no change here.
create or replace function public.staff_list_stock_sync_categories(p_admin_username text, p_admin_password text)
returns table(code text, description text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select c."Code"::text, coalesce(nullif(trim(c."Description"), ''), c."Code")::text
    from public."Categories" c
    where exists (select 1 from public."Items" i where i."CategoryCode" = c."Code")
    order by 2;
end;
$$;

grant execute on function public.staff_list_stock_sync_categories(text, text) to anon;

-- ============================================================================
-- SALES
-- ============================================================================
-- Handled in supabase_item_ledger_sales.sql (run after this file): a confirmed order takes its stock
-- out of the ledger. Until the opening-balance seed switches that on, sales do NOT reduce the
-- ledger.

notify pgrst, 'reload schema';

-- Verification. Expect three trigger rows (two on the ledger, one on Transfer_Line).
select tgname, tgrelid::regclass as on_table
from pg_trigger
where tgname in ('TR_Transfer_Line_ItemLedger', 'TR_ItemLedgerEntries_NoUpdateDelete', 'TR_ItemLedgerEntries_NoTruncate')
  and not tgisinternal;
