-- Pushes Transfer Order shipments to Pancake Cloud (pos.pages.fm), mirroring the standalone
-- FinancePurchasePayroll app's SyncTransferToCloudAsync/CompleteTransferToCloudAsync
-- (PurchaseOrderService.cs) but adapted to the portal's own multi-step Ship/Receive workflow
-- (see js/transferOrders.js) instead of a single one-shot post.
--
-- Pancake's transfer API has no "add more items to an existing transfer" call - only create
-- (POST /transfers/multi) then mark Completed (PUT /transfers/{id}, status:2). Since the portal
-- supports partial shipments (multiple Ship clicks building up a running total per line), EVERY
-- Ship action - even a partial one - creates its OWN separate Pancake transfer covering just that
-- action's shipped quantities. A portal order shipped across several partial shipments therefore
-- ends up with several Pancake transfer records, each tracked as its own row here. All of an
-- order's still-open ("Synced") Pancake transfers are marked Completed together as soon as
-- everything actually SHIPPED has been received locally - not gated on the order's own Status
-- reaching the literal "Received" label, since a short-shipped order (less delivered than
-- originally requested) would otherwise never reach that label at all (see
-- staff_complete_transfer_pancake_shipments and receiveTransferOrder in transferOrders.js). Per
-- direct instruction, Receive is now BLOCKED entirely unless that completion actually succeeds -
-- same as Ship blocks on a failed/unconfirmed create - so the portal never marks/archives an
-- order locally as received when Pancake doesn't also reflect it as done.
--
-- staff_complete_transfer_pancake_shipments reports EVERY still-'Synced' row for the order,
-- including one with no "Pancake Transfer ID" at all (the original create silently never
-- succeeded) - that used to be excluded from the query entirely, so the caller had no way to know
-- it existed. It's now reported as its own explicit failure so it surfaces in the UI instead of
-- silently lingering forever.
--
-- staff_sync_transfer_shipment_to_pancake distinguishes two kinds of create failure, though per
-- direct instruction the caller (shipTransferOrder in transferOrders.js) now BLOCKS the whole
-- Ship action on either one - nothing is written to Transfer_Line/Transfer_Header locally unless
-- Pancake actually confirms the transfer ('Synced'). Nothing in THIS file ever blocks anything
-- itself - these functions just report a status, and it's the caller's choice - but the
-- distinction is kept because the two cases explain themselves very differently to staff:
--   'Rejected' - Pancake gave back an actual HTTP 4xx response explicitly refusing the request
--     (e.g. insufficient stock at the source warehouse) - a real "no" that won't change on retry
--     until the underlying stock issue is fixed.
--   'Failed' - unreachable/timeout/5xx/unknown - we genuinely don't know whether it went through
--     or not; staff can retry via staff_retry_transfer_pancake_shipment once Pancake is reachable
--     again (that retry is itself the "verify instead of resubmit" pattern below, so it's safe to
--     press repeatedly).
--
-- IMPORTANT - never blindly retry the create call: POST /transfers/multi is NOT idempotent, so
-- resubmitting it on a transport error (e.g. the connection dropping while reading Pancake's
-- response, even though Pancake already received and processed the request) can create a second,
-- duplicate transfer - which is exactly what happened during testing (a transfer really was
-- created in Pancake, but the local read failed, and a blind retry then hit a stock-validation
-- rejection because the first attempt had already consumed the available stock). Instead, every
-- create attempt below tags its payload with a unique "note" (Document No. + Shipment Event No.)
-- and, on ANY failure, calls _pancake_find_transfer_id_by_note() to check whether that exact
-- transfer actually made it into Pancake before concluding it failed/rejected - so a genuine
-- business rejection still reports 'Rejected' correctly, but a request that silently succeeded
-- despite a local read error is picked up as 'Synced' instead of duplicated.
--
-- Uses the same Pancake base URL/shop id/api key already hardcoded in
-- supabase_pancake_manual_sync.sql's admin_sync_warehouses_from_pancake/admin_sync_items_from_pancake.
-- The transfers list endpoint (GET /shops/{id}/transfers?page=..&page_size=..) is the same one
-- the desktop app's own PostingEvents.SyncLatestTransfersToLocalDb() already pulls from - its
-- response envelope (array root, or {"transfers"|"data"|"items": [...]}) and per-transfer "note"
-- field (== the document/shipment note we set on create - see GetTransferDocumentNo) are already
-- confirmed by that code.

create table if not exists public."Transfer_Pancake_Shipments" (
    "ShipmentEventNo" bigint generated always as identity primary key,
    "Document No." varchar(50) not null,
    "From Warehouse ID" varchar(100),
    "To Warehouse ID" varchar(100),
    "Items Json" jsonb not null,
    "Pancake Transfer ID" varchar(100),
    "Sync Status" varchar(20) not null default 'Pending', -- Pending | Synced | Completed | Failed | Rejected
    "Sync Error" text,
    "Shipped By" varchar(100),
    "Shipped At Utc" timestamptz not null default now(),
    "Completed At Utc" timestamptz
);

create index if not exists "IX_Transfer_Pancake_Shipments_DocNo" on public."Transfer_Pancake_Shipments" ("Document No.");

alter table public."Transfer_Pancake_Shipments" enable row level security;
revoke all on public."Transfer_Pancake_Shipments" from anon, authenticated;

drop function if exists public._pancake_find_transfer_id_by_note(text);

-- Internal helper - NOT granted to anon, only called from the create-attempt functions below
-- after a failure, to check whether Pancake actually created the transfer despite the local
-- error (see this file's header comment for why blind retry of the create call is unsafe).
-- Scans GET /shops/{id}/transfers (newest activity first, per Pancake's own ordering) up to
-- v_max_pages * 1000 records looking for an exact "note" match, mirroring the desktop app's own
-- PostingEvents.SyncLatestTransfersToLocalDb() pull loop. Returns null (not an exception) on any
-- lookup failure - the caller falls back to reporting the original error rather than a confusing
-- second one.
create or replace function public._pancake_find_transfer_id_by_note(p_note text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_page int := 1;
  v_max_pages int := 5;
  v_response extensions.http_response;
  v_body jsonb;
  v_items jsonb;
  v_item jsonb;
  v_found_id text;
begin
  if p_note is null or trim(p_note) = '' then
    return null;
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

  while v_page <= v_max_pages loop
    select * into v_response from extensions.http_get(
      v_base_url || '/shops/' || v_shop_id || '/transfers?api_key=' || v_api_key || '&page_size=1000&page=' || v_page::text
    );

    if v_response.status < 200 or v_response.status >= 300 then
      return null;
    end if;

    v_body := v_response.content::jsonb;
    v_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'transfers') = 'array' then v_body -> 'transfers'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'items') = 'array' then v_body -> 'items'
      else '[]'::jsonb
    end;

    if jsonb_array_length(v_items) = 0 then
      return null;
    end if;

    for v_item in select * from jsonb_array_elements(v_items)
    loop
      if v_item ->> 'note' = p_note then
        v_found_id := coalesce(nullif(v_item ->> 'id', ''), nullif(v_item ->> 'transfer_id', ''));
        if v_found_id is not null then
          return v_found_id;
        end if;
      end if;
    end loop;

    if jsonb_array_length(v_items) < 1000 then
      return null;
    end if;

    v_page := v_page + 1;
  end loop;

  return null;
exception when others then
  return null;
end;
$$;

drop function if exists public._pancake_error_detail(int, text);

-- Shared formatter for a non-2xx Pancake response, used at every raise-on-bad-status site below.
-- Pancake's own error bodies are JSON with a "message" field (e.g. {"error":1,"message":"khong
-- du so luong ton kho"}) - raising the raw response body as-is (the old behavior) buried that
-- message in JSON punctuation and was what the portal's UI showed verbatim to staff. Pulling just
-- the message out keeps sqlerrm short and lets the caller's friendlyPancakeErrorMessage() (see
-- transferOrders.js) pattern-match it cleanly; falls back to the raw body if it isn't JSON.
create or replace function public._pancake_error_detail(p_status int, p_content text)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_msg text;
begin
  begin
    v_msg := nullif(trim(both from (p_content::jsonb ->> 'message')), '');
  exception when others then
    v_msg := null;
  end;
  return format('HTTP %s: %s', p_status, coalesce(v_msg, p_content));
end;
$$;

drop function if exists public.staff_sync_transfer_shipment_to_pancake(text, text, text, text, text, jsonb, text);

-- Called right after a Ship action commits locally (see shipTransferOrder in transferOrders.js).
-- p_items: jsonb array of {"item_no": "...", "variant_id": "..." (nullable), "quantity": n} for
-- just this shipment's increments. Resolves each line's Pancake variation_id the same way
-- FinancePurchasePayroll's ResolveCloudVariationId does: prefer the line's own Variant ID
-- (already Pancake's own id - see Transfer_Line."Variant ID"/Variants."VariationId"), falling
-- back to the item's own single/default Items."VariationId" for items with no variant selected.
-- Always inserts a row (even on failure) and never raises past that point - the HTTP call is
-- wrapped so a Pancake-side failure comes back as a normal 'Failed' result row, not a thrown
-- error, letting the caller show a non-blocking warning.
create or replace function public.staff_sync_transfer_shipment_to_pancake(
  p_admin_username text,
  p_admin_password text,
  p_document_no text,
  p_from_warehouse_id text,
  p_to_warehouse_id text,
  p_items jsonb,
  p_shipped_by text default null
)
returns table(shipment_event_no bigint, sync_status text, pancake_transfer_id text, sync_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_event_no bigint;
  v_note text;
  v_resolved_items jsonb := '[]'::jsonb;
  v_item jsonb;
  v_variation_id text;
  v_quantity numeric;
  v_payload jsonb;
  v_endpoint text;
  v_response extensions.http_response;
  v_body jsonb;
  v_transfer_id text;
  v_found_id text;
  v_last_http_status int;
  v_status text;
  v_error text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_document_no is null or trim(p_document_no) = '' then
    raise exception 'Document No. is required.';
  end if;
  if p_from_warehouse_id is null or trim(p_from_warehouse_id) = ''
     or p_to_warehouse_id is null or trim(p_to_warehouse_id) = '' then
    raise exception 'Both From and To Warehouse IDs are required to sync to Pancake.';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_quantity := coalesce((v_item ->> 'quantity')::numeric, 0);
    if v_quantity <= 0 then
      continue;
    end if;

    v_variation_id := nullif(trim(v_item ->> 'variant_id'), '');
    if v_variation_id is null then
      select "VariationId" into v_variation_id
      from public."Items"
      where "Code" = (v_item ->> 'item_no') or "ProductId" = (v_item ->> 'item_no')
      limit 1;
    end if;

    if v_variation_id is null or trim(v_variation_id) = '' then
      raise exception 'Item No. "%" has no Pancake variation id - cannot sync to Pancake.', v_item ->> 'item_no';
    end if;

    v_resolved_items := v_resolved_items || jsonb_build_object('variation_id', v_variation_id, 'quantity', v_quantity);
  end loop;

  if jsonb_array_length(v_resolved_items) = 0 then
    raise exception 'No line items to sync to Pancake.';
  end if;

  insert into public."Transfer_Pancake_Shipments"
    ("Document No.", "From Warehouse ID", "To Warehouse ID", "Items Json", "Shipped By")
  values (p_document_no, p_from_warehouse_id, p_to_warehouse_id, v_resolved_items, p_shipped_by)
  returning "ShipmentEventNo" into v_event_no;

  -- Unique per shipment event (not just per order) so a failed-attempt lookup below can find
  -- exactly this attempt's transfer, even if the same order was shipped in several partial
  -- batches (which would otherwise all share the same Document No. as their note).
  v_note := p_document_no || '-' || v_event_no::text;

  v_status := 'Failed';
  v_transfer_id := null;
  v_error := null;
  v_last_http_status := null;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

    v_payload := jsonb_build_object(
      'transfer', jsonb_build_object(
        'from_warehouse_id', p_from_warehouse_id,
        'to_warehouse_ids', jsonb_build_array(p_to_warehouse_id),
        'shipping_fee', 0,
        'items', v_resolved_items,
        'note', v_note,
        'inserted_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS')
      )
    );

    v_endpoint := v_base_url || '/shops/' || v_shop_id || '/transfers/multi?api_key=' || v_api_key;

    select * into v_response from extensions.http((
      'POST',
      v_endpoint,
      array[]::extensions.http_header[],
      'application/json',
      v_payload::text
    )::extensions.http_request);

    v_last_http_status := v_response.status;

    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake Cloud transfer sync failed (%)', public._pancake_error_detail(v_response.status, v_response.content);
    end if;

    v_body := v_response.content::jsonb;
    v_transfer_id := coalesce(
      nullif(v_body ->> 'id', ''),
      nullif(v_body ->> 'transfer_id', ''),
      nullif(v_body -> 'data' ->> 'id', ''),
      nullif(v_body -> 'transfer' ->> 'id', '')
    );

    if v_transfer_id is null then
      raise exception 'Pancake Cloud transfer sync succeeded but no transfer id was returned.';
    end if;

    v_status := 'Synced';
  exception when others then
    -- POST /transfers/multi is not idempotent, so this never blindly retries the same request -
    -- see this file's header comment. Instead, check whether Pancake actually created it despite
    -- the local error (e.g. the connection dropped while reading the response) before concluding
    -- it failed; a genuine rejection (bad stock, etc.) will correctly find nothing here.
    v_error := sqlerrm;
    v_found_id := public._pancake_find_transfer_id_by_note(v_note);
    if v_found_id is not null then
      v_transfer_id := v_found_id;
      v_status := 'Synced';
      v_error := null;
    elsif v_last_http_status is not null and v_last_http_status between 400 and 499 then
      -- Pancake gave us an actual response explicitly rejecting the request (e.g. insufficient
      -- stock at the source warehouse) - distinct from 'Failed' (unreachable/timeout/5xx, where
      -- we genuinely don't know if it went through) so the caller (shipTransferOrder in
      -- transferOrders.js) can block the whole Ship action on a real rejection, while still
      -- letting an unreachable-Pancake situation fall back to "warn but don't block".
      v_status := 'Rejected';
    else
      v_status := 'Failed';
    end if;
  end;

  update public."Transfer_Pancake_Shipments"
    set "Pancake Transfer ID" = v_transfer_id,
        "Sync Status" = v_status,
        "Sync Error" = v_error
    where "ShipmentEventNo" = v_event_no;

  return query select v_event_no, v_status, v_transfer_id, v_error;
end;
$$;

drop function if exists public.staff_complete_transfer_pancake_shipments(text, text, text);

-- Called once a Transfer Order reaches full Received status (see receiveTransferOrder in
-- transferOrders.js, right before archiving). Marks every one of this order's still-open
-- ("Synced") Pancake transfers Completed (status:2) - there can be more than one if the order was
-- shipped across several partial shipments. A transfer whose completion call fails is left as
-- 'Synced' (not 'Failed') with its Sync Error set, so it stays eligible to complete again later
-- (via a re-run of this same function, or staff_retry_transfer_pancake_shipment) instead of
-- needing a brand new Pancake transfer.
create or replace function public.staff_complete_transfer_pancake_shipments(
  p_admin_username text,
  p_admin_password text,
  p_document_no text
)
returns table(shipment_event_no bigint, sync_status text, pancake_transfer_id text, sync_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_row record;
  v_endpoint text;
  v_payload jsonb;
  v_response extensions.http_response;
  v_status text;
  v_error text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Was previously "... and Pancake Transfer ID is not null", which silently excluded any row
  -- missing an id from this whole loop - it would never be attempted AND never show up in the
  -- result set, so the caller (receiveTransferOrder in transferOrders.js) had no way to know that
  -- shipment even existed, let alone that it needed attention. Every 'Synced' row for this order
  -- is now included, and a missing id is reported as its own explicit failure below instead.
  for v_row in
    select * from public."Transfer_Pancake_Shipments"
    where "Document No." = p_document_no and "Sync Status" = 'Synced'
  loop
    if v_row."Pancake Transfer ID" is null then
      v_status := 'Synced';
      v_error := 'No Pancake Transfer ID was ever recorded for this shipment - the original create may have failed silently. Use Retry to re-verify/re-create it in Pancake before it can be completed.';
    else
      v_status := 'Completed';
      v_error := null;

      begin
        perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

        v_payload := jsonb_build_object(
          'transfer', jsonb_build_object(
            'status', 2,
            'from_warehouse_id', v_row."From Warehouse ID",
            'to_warehouse_id', v_row."To Warehouse ID"
          )
        );

        v_endpoint := v_base_url || '/shops/' || v_shop_id || '/transfers/' || v_row."Pancake Transfer ID" || '?api_key=' || v_api_key;

        -- Same one-retry-on-transport-failure-only pattern as staff_sync_transfer_shipment_to_pancake
        -- above - see that function's comment for why this never retries a genuine HTTP error.
        begin
          select * into v_response from extensions.http((
            'PUT',
            v_endpoint,
            array[]::extensions.http_header[],
            'application/json',
            v_payload::text
          )::extensions.http_request);
        exception when others then
          perform pg_sleep(0.5);
          select * into v_response from extensions.http((
            'PUT',
            v_endpoint,
            array[]::extensions.http_header[],
            'application/json',
            v_payload::text
          )::extensions.http_request);
        end;

        if v_response.status < 200 or v_response.status >= 300 then
          raise exception 'Pancake Cloud transfer completion failed (%)', public._pancake_error_detail(v_response.status, v_response.content);
        end if;
      exception when others then
        v_status := 'Synced';
        v_error := sqlerrm;
      end;
    end if;

    update public."Transfer_Pancake_Shipments"
      set "Sync Status" = v_status,
          "Sync Error" = v_error,
          "Completed At Utc" = case when v_status = 'Completed' then now() else "Completed At Utc" end
      where "ShipmentEventNo" = v_row."ShipmentEventNo";

    shipment_event_no := v_row."ShipmentEventNo";
    sync_status := v_status;
    pancake_transfer_id := v_row."Pancake Transfer ID";
    sync_error := v_error;
    return next;
  end loop;
end;
$$;

drop function if exists public.staff_retry_transfer_pancake_shipment(text, text, bigint);

-- Manual retry for a single shipment event (Manage modal's Pancake Sync panel - see
-- transferOrders.js). If it never made it into Pancake at all ('Failed', no transfer id), re-POST
-- using the same stored Items Json/warehouse ids rather than requiring the caller to recompute
-- them. If it's already in Pancake but failed to complete ('Synced' with an error), retries just
-- the completion step instead of creating a second duplicate transfer.
create or replace function public.staff_retry_transfer_pancake_shipment(
  p_admin_username text,
  p_admin_password text,
  p_shipment_event_no bigint
)
returns table(shipment_event_no bigint, sync_status text, pancake_transfer_id text, sync_error text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_row record;
  v_note text;
  v_payload jsonb;
  v_endpoint text;
  v_response extensions.http_response;
  v_body jsonb;
  v_transfer_id text;
  v_found_id text;
  v_last_http_status int;
  v_status text;
  v_error text;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  select * into v_row from public."Transfer_Pancake_Shipments" where "ShipmentEventNo" = p_shipment_event_no;
  if not found then
    raise exception 'Shipment sync record not found.';
  end if;

  if v_row."Sync Status" = 'Completed' then
    shipment_event_no := v_row."ShipmentEventNo";
    sync_status := v_row."Sync Status";
    pancake_transfer_id := v_row."Pancake Transfer ID";
    sync_error := null;
    return next;
    return;
  end if;

  if v_row."Sync Status" = 'Synced' and v_row."Pancake Transfer ID" is not null then
    return query
      select c.shipment_event_no, c.sync_status, v_row."Pancake Transfer ID", c.sync_error
      from public.staff_complete_transfer_pancake_shipments(p_admin_username, p_admin_password, v_row."Document No.") c
      where c.shipment_event_no = p_shipment_event_no;
    return;
  end if;

  -- Same deterministic note as the original create attempt (Document No. + Shipment Event No.,
  -- see staff_sync_transfer_shipment_to_pancake) - reconstructed here rather than stored, so the
  -- verify-by-note lookup below can find it regardless of which attempt actually created it.
  -- (Rows created before this note format changed used a plain Document No. as their note - a
  -- retry on one of those very old rows could in theory miss an existing match and create a
  -- second transfer; harmless in practice since that only affects already-stuck rows from before
  -- this fix shipped.)
  v_note := v_row."Document No." || '-' || v_row."ShipmentEventNo"::text;

  v_status := 'Failed';
  v_transfer_id := null;
  v_error := null;
  v_last_http_status := null;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');

    v_payload := jsonb_build_object(
      'transfer', jsonb_build_object(
        'from_warehouse_id', v_row."From Warehouse ID",
        'to_warehouse_ids', jsonb_build_array(v_row."To Warehouse ID"),
        'shipping_fee', 0,
        'items', v_row."Items Json",
        'note', v_note,
        'inserted_at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS')
      )
    );

    v_endpoint := v_base_url || '/shops/' || v_shop_id || '/transfers/multi?api_key=' || v_api_key;

    select * into v_response from extensions.http((
      'POST',
      v_endpoint,
      array[]::extensions.http_header[],
      'application/json',
      v_payload::text
    )::extensions.http_request);

    v_last_http_status := v_response.status;

    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake Cloud transfer sync failed (%)', public._pancake_error_detail(v_response.status, v_response.content);
    end if;

    v_body := v_response.content::jsonb;
    v_transfer_id := coalesce(
      nullif(v_body ->> 'id', ''),
      nullif(v_body ->> 'transfer_id', ''),
      nullif(v_body -> 'data' ->> 'id', ''),
      nullif(v_body -> 'transfer' ->> 'id', '')
    );

    if v_transfer_id is null then
      raise exception 'Pancake Cloud transfer sync succeeded but no transfer id was returned.';
    end if;

    v_status := 'Synced';
  exception when others then
    -- Same not-idempotent-so-verify-instead-of-retry approach as
    -- staff_sync_transfer_shipment_to_pancake - see this file's header comment.
    v_error := sqlerrm;
    v_found_id := public._pancake_find_transfer_id_by_note(v_note);
    if v_found_id is not null then
      v_transfer_id := v_found_id;
      v_status := 'Synced';
      v_error := null;
    elsif v_last_http_status is not null and v_last_http_status between 400 and 499 then
      v_status := 'Rejected';
    else
      v_status := 'Failed';
    end if;
  end;

  update public."Transfer_Pancake_Shipments"
    set "Pancake Transfer ID" = coalesce(v_transfer_id, "Pancake Transfer ID"),
        "Sync Status" = v_status,
        "Sync Error" = v_error
    where "ShipmentEventNo" = p_shipment_event_no;

  shipment_event_no := p_shipment_event_no;
  sync_status := v_status;
  pancake_transfer_id := v_transfer_id;
  sync_error := v_error;
  return next;
end;
$$;

drop function if exists public.staff_list_transfer_pancake_shipments(text, text, text);

create or replace function public.staff_list_transfer_pancake_shipments(p_admin_username text, p_admin_password text, p_document_no text)
returns table(
  shipment_event_no bigint,
  pancake_transfer_id text,
  sync_status text,
  sync_error text,
  shipped_by text,
  shipped_at_utc timestamptz,
  completed_at_utc timestamptz
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
    select "ShipmentEventNo", "Pancake Transfer ID"::text, "Sync Status"::text, "Sync Error"::text,
           "Shipped By"::text, "Shipped At Utc", "Completed At Utc"
    from public."Transfer_Pancake_Shipments"
    where "Document No." = p_document_no
    order by "Shipped At Utc" desc;
end;
$$;

grant execute on function public.staff_sync_transfer_shipment_to_pancake(text, text, text, text, text, jsonb, text) to anon;
grant execute on function public.staff_complete_transfer_pancake_shipments(text, text, text) to anon;
grant execute on function public.staff_retry_transfer_pancake_shipment(text, text, bigint) to anon;
grant execute on function public.staff_list_transfer_pancake_shipments(text, text, text) to anon;
