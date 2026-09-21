-- Item Ledger Entries - wires the stock-moving workflows into the ledger, per "i want to involve
-- every feature inside the item ledger entry, so every item that is moving same as business
-- central. Also i want per variant be covered as well".
--
-- Run AFTER supabase_item_ledger_entries.sql (the ledger, _ile_post and the adjustment/reversal
-- RPCs). Run this BEFORE deploying the matching docs/js/transferOrders.js change - that script
-- starts writing a new "Last Actor" column this file adds.
--
-- WHAT NOW WRITES TO THE LEDGER
--   Purchase Order receive        -> 'Purchase'  +qty at the line's warehouse, per the line's variant
--   Purchase Order manual confirm -> 'Purchase'  same, for the super-user "already in Pancake" path
--   Transfer Order ship           -> 'Transfer'  -qty at the From warehouse (stock is in transit)
--   Transfer Order receive        -> 'Transfer'  +qty at the To warehouse
--   Manual adjustments/reversals  -> already covered by supabase_item_ledger_entries.sql
-- NOT covered yet: Sales (see the note at the bottom).
--
-- WHY SOME ARE TRIGGERS AND SOME ARE INLINE
--   * Purchase Orders: the receive functions are ours, so the ledger post is written inline next to
--     the QtyReceived update, attributed to the acting user.
--   * Transfer Orders: Ship/Receive commit through raw browser table writes (upsertRow on
--     Transfer_Line), not an RPC - so the only way to make the ledger write atomic with the
--     quantity change is a trigger on Transfer_Line.
--
-- A LEDGER FAILURE MUST NEVER BREAK THE WORKFLOW. Both workflows only commit locally AFTER
-- Pancake has already accepted the stock movement, so a ledger error that rolled the receipt back
-- would leave Pancake and the portal disagreeing and invite a duplicate on retry. Every automatic
-- posting therefore goes through _ile_post_safe: on any error it writes the movement to
-- ItemLedgerPostingFailures instead (shown as a banner on the Item Ledger Entries page) and lets
-- the workflow carry on. A failed movement is fixed by correcting the cause and posting the missing
-- quantity as an adjustment, then dismissing the failure.

-- ============================================================================
-- 1. Failure queue + safe posting wrapper
-- ============================================================================

create table if not exists public."ItemLedgerPostingFailures" (
    "Id" bigint generated always as identity primary key,
    "EntryType" varchar(20),
    "ItemCode" varchar(200),
    "VariantId" varchar(100),
    "WarehouseId" varchar(100),
    "Quantity" numeric(18, 4),
    "PostingDate" date,
    "DocumentType" varchar(40),
    "DocumentNo" varchar(50),
    "Description" varchar(500),
    "ErrorMessage" text not null,
    "PostedBy" varchar(100),
    "CreatedAtUtc" timestamptz not null default now(),
    "DismissedAtUtc" timestamptz,
    "DismissedBy" varchar(100)
);

alter table public."ItemLedgerPostingFailures" enable row level security;
revoke all on public."ItemLedgerPostingFailures" from anon, authenticated;

create index if not exists "IX_ItemLedgerPostingFailures_Open" on public."ItemLedgerPostingFailures" ("CreatedAtUtc") where "DismissedAtUtc" is null;

-- Same arguments as _ile_post (minus reverses_entry_no). Returns the new EntryNo, or null if the
-- posting failed and was queued instead.
create or replace function public._ile_post_safe(
  p_entry_type text,
  p_item_code text,
  p_variant_id text,
  p_warehouse_id text,
  p_quantity numeric,
  p_posting_date date,
  p_document_type text,
  p_document_no text,
  p_description text,
  p_transaction_no bigint,
  p_posted_by text
)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return public._ile_post(
    p_entry_type, p_item_code, p_variant_id, p_warehouse_id, p_quantity, p_posting_date,
    p_document_type, p_document_no, p_description, p_transaction_no, p_posted_by
  );
exception when others then
  -- The failed _ile_post was rolled back to this block's savepoint; the queue row below lands in
  -- the caller's transaction and so survives as long as the workflow itself commits.
  insert into public."ItemLedgerPostingFailures" (
    "EntryType", "ItemCode", "VariantId", "WarehouseId", "Quantity", "PostingDate",
    "DocumentType", "DocumentNo", "Description", "ErrorMessage", "PostedBy"
  )
  values (
    p_entry_type, p_item_code, nullif(trim(coalesce(p_variant_id, '')), ''), p_warehouse_id, p_quantity,
    p_posting_date, p_document_type, p_document_no, left(p_description, 500), sqlerrm, p_posted_by
  );
  return null;
end;
$$;

revoke execute on function public._ile_post_safe(text, text, text, text, numeric, date, text, text, text, bigint, text) from public, anon, authenticated;

drop function if exists public.admin_list_item_ledger_posting_failures(text, text);

create or replace function public.admin_list_item_ledger_posting_failures(
  p_admin_username text,
  p_admin_password text
)
returns table(
  id bigint, entry_type text, item_code text, variant_id text, warehouse_id text, warehouse_name text,
  quantity numeric, posting_date date, document_type text, document_no text, description text,
  error_message text, posted_by text, created_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select f."Id", f."EntryType"::text, f."ItemCode"::text, f."VariantId"::text, f."WarehouseId"::text,
           coalesce(w."Name", f."WarehouseId")::text, f."Quantity", f."PostingDate",
           f."DocumentType"::text, f."DocumentNo"::text, f."Description"::text, f."ErrorMessage",
           f."PostedBy"::text, f."CreatedAtUtc"
    from public."ItemLedgerPostingFailures" f
    left join public."Warehouses" w on w."ID" = f."WarehouseId"
    where f."DismissedAtUtc" is null
    order by f."CreatedAtUtc" desc
    limit 200;
end;
$$;

grant execute on function public.admin_list_item_ledger_posting_failures(text, text) to anon;

drop function if exists public.admin_dismiss_item_ledger_posting_failure(text, text, bigint);

create or replace function public.admin_dismiss_item_ledger_posting_failure(
  p_admin_username text,
  p_admin_password text,
  p_id bigint
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  update public."ItemLedgerPostingFailures"
     set "DismissedAtUtc" = now(), "DismissedBy" = p_admin_username
   where "Id" = p_id and "DismissedAtUtc" is null;
end;
$$;

grant execute on function public.admin_dismiss_item_ledger_posting_failure(text, text, bigint) to anon;

-- ============================================================================
-- 2. Purchase Order receiving
-- ============================================================================

-- Body is supabase_purchase_order_pancake_stock_verification_fix.sql's staff_receive_purchase_
-- order_lines (the latest version of this function in the repo) with two changes:
--   1. The per-variant Pancake variation lookup from supabase_purchase_order_receive_variant_stock.sql
--      is put back. The later verification/fix migrations were rebuilt from the ORIGINAL sync
--      version and quietly dropped it, so if they were run after it, receiving has been stocking
--      Pancake against the item's representative variation instead of the line's own variant.
--   2. Where QtyReceived is incremented, the same quantity is now posted to the Item Ledger
--      (PurchaseOrderLines.Quantity is already in BASE units - the typed UoM quantity lives in
--      QuantityUom - so the increment goes in as-is).
-- Nothing about the Pancake call, the sync-status handling or the running-total rule changed.

drop function if exists public.staff_receive_purchase_order_lines(text, text, text, jsonb);

create or replace function public.staff_receive_purchase_order_lines(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_lines jsonb
)
returns table(warehouse_id text, warehouse_name text, sync_status text, pancake_purchase_id text, sync_error text, entry_nos bigint[])
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_line jsonb;
  v_entry_no bigint;
  v_requested numeric;
  v_po_line record;
  v_remaining numeric;
  v_increment numeric;
  v_variation_id text;
  v_staged jsonb := '[]'::jsonb; -- {entry_no, warehouse_id, warehouse_name, variation_id, quantity, item_code, variant_code}
  v_any_staged boolean := false;
  v_warehouse_ids text[];
  v_wh text;
  v_wh_items jsonb;
  v_wh_entry_nos bigint[];
  v_wh_name text;
  v_item jsonb;
  v_payload jsonb;
  v_endpoint text;
  v_response extensions.http_response;
  v_body jsonb;
  v_purchase_id text;
  v_status text;
  v_error text;
  v_event_no bigint;
  v_note text;
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

  -- Stage + resolve every requested line BEFORE any Pancake call - a missing Warehouse/variation
  -- id is a data problem that needs fixing, not something to silently skip mid-batch.
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

    v_remaining := greatest(0, v_po_line."Quantity" - v_po_line."QtyReceived");
    v_increment := least(v_requested, v_remaining);
    if v_increment <= 0 then
      continue;
    end if;

    if v_po_line."WarehouseId" is null or trim(v_po_line."WarehouseId") = '' then
      raise exception 'Item "%" has no Warehouse on this line - cannot sync to Pancake.', v_po_line."ItemCode";
    end if;

    -- The line's own variant first - the variant actually picked/ordered - falling back to the
    -- item's representative variation only when the line carries none. A blank VariantCode ('')
    -- is treated the same as no variant.
    if v_po_line."VariantCode" is not null and trim(v_po_line."VariantCode") <> '' then
      v_variation_id := trim(v_po_line."VariantCode");
    else
      select "VariationId" into v_variation_id from public."Items" where "Code" = v_po_line."ItemCode" limit 1;
    end if;

    if v_variation_id is null or trim(v_variation_id) = '' then
      raise exception 'Item "%" has no Pancake variation id - cannot sync to Pancake.', v_po_line."ItemCode";
    end if;

    v_staged := v_staged || jsonb_build_object(
      'entry_no', v_entry_no,
      'warehouse_id', v_po_line."WarehouseId",
      'warehouse_name', v_po_line."WarehouseName",
      'variation_id', v_variation_id,
      'quantity', v_increment,
      'item_code', v_po_line."ItemCode",
      -- The LEDGER's variant is only the line's own variant. The Items.VariationId fallback above
      -- is a Pancake routing detail, not a statement that the line was ordered as that variant.
      'variant_code', coalesce(nullif(trim(coalesce(v_po_line."VariantCode", '')), ''), '')
    );
    v_any_staged := true;
  end loop;

  if not v_any_staged then
    raise exception 'No matching line(s) with a quantity greater than zero remain to be received.';
  end if;

  select array_agg(distinct x ->> 'warehouse_id') into v_warehouse_ids from jsonb_array_elements(v_staged) x;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

  foreach v_wh in array v_warehouse_ids
  loop
    v_wh_items := '[]'::jsonb;
    v_wh_entry_nos := array[]::bigint[];
    v_wh_name := null;

    for v_item in select value from jsonb_array_elements(v_staged) where value ->> 'warehouse_id' = v_wh
    loop
      v_wh_items := v_wh_items || jsonb_build_object(
        'quantity', (v_item ->> 'quantity')::numeric,
        'variation_id', v_item ->> 'variation_id',
        'index', jsonb_array_length(v_wh_items)
      );
      v_wh_entry_nos := v_wh_entry_nos || (v_item ->> 'entry_no')::bigint;
      v_wh_name := coalesce(v_wh_name, v_item ->> 'warehouse_name');
    end loop;

    insert into public."PurchaseOrder_Pancake_Purchases" ("PONo", "WarehouseId", "WarehouseName", "Items Json", "ReceivedBy")
    values (p_po_no, v_wh, v_wh_name, v_wh_items, p_admin_username)
    returning "PurchaseEventNo" into v_event_no;

    v_note := p_po_no || '-' || v_event_no::text;
    v_status := 'Failed';
    v_purchase_id := null;
    v_error := null;

    begin
      v_payload := jsonb_build_object(
        'purchase', jsonb_build_object(
          'note', v_note,
          'status', 1,
          'not_create_transaction', true,
          'auto_create_debts', true,
          'shop_id', v_shop_id,
          'warehouse_id', v_wh,
          'change_received_at', true,
          'items', v_wh_items
        )
      );

      v_endpoint := v_base_url || '/shops/' || v_shop_id || '/purchases?api_key=' || v_api_key;

      select * into v_response from extensions.http((
        'POST',
        v_endpoint,
        array[]::extensions.http_header[],
        'application/json',
        v_payload::text
      )::extensions.http_request);

      if v_response.status < 200 or v_response.status >= 300 then
        v_status := case when v_response.status between 400 and 499 then 'Rejected' else 'Failed' end;
        v_error := public._pancake_error_detail(v_response.status, v_response.content);
      else
        v_body := v_response.content::jsonb;
        v_purchase_id := coalesce(
          nullif(v_body ->> 'id', ''),
          nullif(v_body -> 'data' ->> 'id', ''),
          nullif(v_body -> 'purchase' ->> 'id', '')
        );
        v_status := 'Synced';
      end if;
    exception when others then
      -- No confirmed GET /purchases list endpoint to verify-before-retry - reported as Failed with
      -- an explicit duplicate-risk warning instead of silently retrying.
      v_status := 'Failed';
      v_error := sqlerrm || ' - if this already went through in Pancake, verify there before receiving this quantity again to avoid a duplicate stock-in.';
    end;

    update public."PurchaseOrder_Pancake_Purchases"
      set "Pancake Purchase ID" = v_purchase_id,
          "Sync Status" = v_status,
          "Sync Error" = v_error
      where "PurchaseEventNo" = v_event_no;

    if v_status = 'Synced' then
      for v_item in select value from jsonb_array_elements(v_staged) where value ->> 'warehouse_id' = v_wh
      loop
        update public."PurchaseOrderLines"
        set "QtyReceived" = least("Quantity", "QtyReceived" + (v_item ->> 'quantity')::numeric)
        where "EntryNo" = (v_item ->> 'entry_no')::bigint and "PONo" = p_po_no;

        -- Item Ledger: the same increment, at the line's warehouse, against the line's variant.
        perform public._ile_post_safe(
          'Purchase',
          v_item ->> 'item_code',
          nullif(v_item ->> 'variant_code', ''),
          v_wh,
          (v_item ->> 'quantity')::numeric,
          public._ile_today(),
          'Purchase Receipt',
          p_po_no,
          'Received against ' || p_po_no,
          null,
          p_admin_username
        );
      end loop;
    end if;

    warehouse_id := v_wh;
    warehouse_name := v_wh_name;
    sync_status := v_status;
    pancake_purchase_id := v_purchase_id;
    sync_error := v_error;
    entry_nos := v_wh_entry_nos;
    return next;
  end loop;
end;
$$;

grant execute on function public.staff_receive_purchase_order_lines(text, text, text, jsonb) to anon;

-- The super-user "Pancake already has it" path (supabase_purchase_order_manual_receive_confirm.sql)
-- moves QtyReceived without a Pancake call, but it is still real stock arriving - so it posts to
-- the ledger too. Body unchanged apart from the ledger post.
drop function if exists public.staff_confirm_purchase_order_receipt_without_sync(text, text, text, jsonb, text);

create or replace function public.staff_confirm_purchase_order_receipt_without_sync(
  p_admin_username text,
  p_admin_password text,
  p_po_no text,
  p_lines jsonb,
  p_confirmation_note text default null
)
returns void
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
  v_updated_count int := 0;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can confirm a receipt without a Pancake sync.';
  end if;

  if not exists (select 1 from public."PurchaseOrders" where "PONo" = p_po_no) then
    raise exception 'Purchase Order "%" not found.', p_po_no;
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'At least one line with a quantity is required.';
  end if;

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

    v_increment := least(v_requested, greatest(0, v_po_line."Quantity" - v_po_line."QtyReceived"));
    if v_increment <= 0 then
      continue;
    end if;

    update public."PurchaseOrderLines"
    set "QtyReceived" = least("Quantity", "QtyReceived" + v_increment)
    where "EntryNo" = v_entry_no;

    perform public._ile_post_safe(
      'Purchase',
      v_po_line."ItemCode",
      nullif(trim(coalesce(v_po_line."VariantCode", '')), ''),
      coalesce(v_po_line."WarehouseId", ''),
      v_increment,
      public._ile_today(),
      'Purchase Receipt',
      p_po_no,
      'Received against ' || p_po_no || ' (confirmed without a Pancake sync)',
      null,
      p_admin_username
    );

    insert into public."PurchaseOrder_Pancake_Purchases"
      ("PONo", "WarehouseId", "WarehouseName", "Items Json", "Sync Status", "Sync Error", "ReceivedBy")
    values (
      p_po_no,
      coalesce(v_po_line."WarehouseId", ''),
      v_po_line."WarehouseName",
      jsonb_build_array(jsonb_build_object('entry_no', v_entry_no, 'item_code', v_po_line."ItemCode", 'quantity', v_increment)),
      'ManuallyConfirmed',
      coalesce(nullif(trim(p_confirmation_note), ''), 'Marked received without a Pancake sync - staff manually verified in Pancake that this stock-in already exists there.'),
      p_admin_username
    );

    v_updated_count := v_updated_count + 1;
  end loop;

  if v_updated_count = 0 then
    raise exception 'No matching line(s) with a quantity greater than zero remain to be received.';
  end if;
end;
$$;

grant execute on function public.staff_confirm_purchase_order_receipt_without_sync(text, text, text, jsonb, text) to anon;

-- ============================================================================
-- 3. Transfer Orders
-- ============================================================================

-- Who performed the Ship/Receive - written by docs/js/transferOrders.js in the same update as the
-- quantity, so the trigger below can attribute the ledger entry. Portal-only, like Qty To Ship /
-- Qty Shipped.
alter table public."Transfer_Line" add column if not exists "Last Actor" varchar(100);

-- Mirrors Business Central's transfer: SHIP takes stock out of the From warehouse (it is now in
-- transit, so it is on nobody's shelf), RECEIVE puts it into the To warehouse. Between the two the
-- balance report shows the quantity missing from both, which is the point.
--
-- Fires on the running totals ("Qty Shipped" / "Qty Received" are cumulative), so it posts the
-- DELTA - a partial shipment posts just that shipment, and a re-save of the same total posts
-- nothing.
--
-- Receive legs are only posted for lines the portal actually shipped ("Qty Shipped" > 0). Qty
-- Received also exists on the desktop's own transfers (same table, synced up) which never carry
-- "Qty Shipped" - those are the desktop/Pancake's business, not this ledger's.
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
    perform public._ile_post_safe(
      'Transfer', new."Item No.", v_variant, coalesce(v_header.from_id, ''), -v_ship_delta,
      public._ile_today(), 'Transfer Shipment', new."Document No.",
      'Shipped to ' || coalesce(v_header.to_name, v_header.to_id, '?'), null, v_actor
    );
  end if;

  if v_recv_delta <> 0 then
    perform public._ile_post_safe(
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

-- ============================================================================
-- SALES - NOT WIRED YET
-- ============================================================================
-- Orders (online and walk-in) arrive in public."OnlineOrders"/"OnlineOrderLines" by sync from
-- Pancake, and their Status is Pancake's (the portal can only set 'To Ship'). There is no portal
-- posting step to hook, so "when does an order count as a sale that takes stock out, and from which
-- warehouse" is a business rule that has to be chosen before it can be built.

notify pgrst, 'reload schema';

-- Verification. Expect the trigger row and both PO functions.
select tgname, tgrelid::regclass as on_table from pg_trigger where tgname in ('TR_Transfer_Line_ItemLedger', 'TR_ItemLedgerEntries_NoUpdateDelete', 'TR_ItemLedgerEntries_NoTruncate') and not tgisinternal;
