-- Pushes Purchase Order receiving to Pancake Cloud (pos.pages.fm) - per direct request ("I may
-- need you purchase the stocks to pancake... I believe we have /purchase implemented before").
-- The desktop app already has this exact integration (OnlinefunctionsEvents.CreatePurchaseOnlineOrder/
-- BuildPurchaseAdjustmentPreview), which posts to:
--   POST {BaseURL}/shops/{ShopId}/purchases?api_key={ApiKey}
--   body: { "purchase": { "note", "status":1, "not_create_transaction":true, "auto_create_debts":true,
--                          "shop_id", "warehouse_id", "change_received_at":true,
--                          "items":[{"quantity","variation_id","index"}, ...] } }
-- Unlike the transfer endpoint (create + separate "complete" call - see
-- supabase_transfer_orders_pancake_sync.sql), a purchase with status:1 is immediately final in
-- Pancake - one POST per warehouse is the whole sync, no second step.
--
-- REQUIRES supabase_purchase_order_receiving.sql and supabase_transfer_orders_pancake_sync.sql to
-- already be applied (reuses their PurchaseOrderLines."QtyReceived"/is_staff_authorized/
-- _pancake_api_key/_pancake_error_detail).
--
-- Every Receive action is pushed to Pancake at the moment it's entered (not deferred to Post) -
-- receiving is when stock actually physically arrives, so that's when Pancake's real inventory
-- needs to reflect it. staff_post_purchase_order (supabase_purchase_order_receiving.sql) still
-- never touches Pancake - it only archives the portal's own bookkeeping record.
--
-- A single Receive action can span lines from more than one Warehouse (a PO can mix Stock On Hand
-- rows from different warehouses under one vendor) - Pancake's purchases endpoint takes one
-- warehouse_id per call, so this groups the requested lines by WarehouseId and issues one Pancake
-- purchase per warehouse group. Per direct precedent (Ship blocks on Pancake in transferOrders.js),
-- a line's local QtyReceived is only ever incremented for a warehouse group that Pancake actually
-- confirmed ('Synced') - a group that fails/is rejected leaves those lines' QtyReceived untouched,
-- so nothing here can ever report "received" locally without Pancake also reflecting it.
--
-- IMPORTANT - unlike the transfer sync, this does NOT attempt to verify-then-retry a failed create:
-- staff_sync_transfer_shipment_to_pancake can safely re-check a failed attempt against
-- GET /shops/{id}/transfers (already confirmed elsewhere in this codebase - see
-- PostingEvents.SyncLatestTransfersToLocalDb), but no equivalent GET /purchases list-by-note lookup
-- is confirmed anywhere in this codebase. Blindly retrying a failed POST /purchases would risk a
-- second, duplicate stock-in if the first attempt actually succeeded in Pancake despite a local
-- read/timeout error. So a failed group is just reported as 'Failed'/'Rejected' with an explicit
-- warning telling staff to check Pancake directly before receiving that quantity again - no
-- automatic retry function is provided here.

create table if not exists public."PurchaseOrder_Pancake_Purchases" (
    "PurchaseEventNo" bigint generated always as identity primary key,
    "PONo" varchar(50) not null,
    "WarehouseId" varchar(200) not null,
    "WarehouseName" varchar(200),
    "Items Json" jsonb not null,
    "Pancake Purchase ID" varchar(100),
    "Sync Status" varchar(20) not null default 'Pending', -- Synced | Failed | Rejected
    "Sync Error" text,
    "ReceivedBy" varchar(100),
    "ReceivedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_PurchaseOrder_Pancake_Purchases_PONo" on public."PurchaseOrder_Pancake_Purchases" ("PONo");

alter table public."PurchaseOrder_Pancake_Purchases" enable row level security;
revoke all on public."PurchaseOrder_Pancake_Purchases" from anon, authenticated;

drop function if exists public.staff_receive_purchase_order_lines(text, text, text, jsonb);

-- p_lines: JSON array of {entry_no, quantity} - `quantity` is the amount being received in THIS
-- action, capped at each line's remaining (Quantity - QtyReceived). Returns one row per Warehouse
-- group actually attempted against Pancake, so the caller can tell exactly which lines' QtyReceived
-- did (Synced) or did not (Failed/Rejected) get updated.
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
  v_staged jsonb := '[]'::jsonb; -- {entry_no, warehouse_id, warehouse_name, variation_id, quantity}
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
  -- id is a data problem that needs fixing, not something to silently skip mid-batch (same
  -- fail-fast-before-any-HTTP-call approach as staff_sync_transfer_shipment_to_pancake).
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

    select "VariationId" into v_variation_id from public."Items" where "Code" = v_po_line."ItemCode" limit 1;
    if v_variation_id is null or trim(v_variation_id) = '' then
      raise exception 'Item "%" has no Pancake variation id - cannot sync to Pancake.', v_po_line."ItemCode";
    end if;

    v_staged := v_staged || jsonb_build_object(
      'entry_no', v_entry_no,
      'warehouse_id', v_po_line."WarehouseId",
      'warehouse_name', v_po_line."WarehouseName",
      'variation_id', v_variation_id,
      'quantity', v_increment
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
      -- No confirmed GET /purchases list endpoint to verify-before-retry (see this file's header
      -- comment) - reported as Failed with an explicit duplicate-risk warning instead of silently
      -- retrying.
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

drop function if exists public.staff_list_purchase_order_pancake_purchases(text, text, text);

-- Pancake Sync panel (Receive Purchase Order modal) - one row per Receive action's Pancake purchase
-- attempt, same shape as staff_list_transfer_pancake_shipments.
create or replace function public.staff_list_purchase_order_pancake_purchases(p_admin_username text, p_admin_password text, p_po_no text)
returns table(
  purchase_event_no bigint,
  warehouse_id text,
  warehouse_name text,
  pancake_purchase_id text,
  sync_status text,
  sync_error text,
  received_by text,
  received_at_utc timestamptz
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
    select "PurchaseEventNo", "WarehouseId"::text, "WarehouseName"::text, "Pancake Purchase ID"::text,
           "Sync Status"::text, "Sync Error"::text, "ReceivedBy"::text, "ReceivedAtUtc"
    from public."PurchaseOrder_Pancake_Purchases"
    where "PONo" = p_po_no
    order by "ReceivedAtUtc" desc;
end;
$$;

grant execute on function public.staff_list_purchase_order_pancake_purchases(text, text, text) to anon;
