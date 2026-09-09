-- Live Pancake stock verification for an ambiguous ('Failed') Receive attempt, per direct request:
-- "is there a way we can check or confirm that the po has been successfully go through? so the
-- status will not show failed even though we pushed already the PO to pancake".
--
-- Pancake still has no confirmed GET/list-by-note endpoint and no confirmed idempotency key (see
-- supabase_purchase_order_pancake_sync.sql's header comment) - there is no way to ask Pancake
-- "does purchase X exist" directly, so a Failed row's status can never be safely auto-flipped to
-- Synced. What Pancake DOES have, already confirmed working elsewhere in this codebase
-- (OnlinefunctionsEvents.GetCloudVariationDetailsForWarehouseAsync), is a per-variation stock
-- lookup: GET /shops/{shop_id}/variations/{variation_id}, which returns current stock per
-- warehouse ("variations_warehouses" -> "remain_quantity"). That can't prove a specific purchase
-- document exists, but it CAN show whether stock moved by roughly the expected amount since the
-- attempt - a much better-informed manual judgement call than guessing or alt-tabbing to Pancake's
-- own dashboard.
--
-- Two pieces:
--   1. Every Receive attempt from now on captures a "before" stock snapshot (per variation) right
--      before it POSTs to Pancake, stored on the same PurchaseOrder_Pancake_Purchases row the
--      attempt itself is logged to. Best-effort only - if the snapshot GET fails, the receive
--      still proceeds; the row just has no baseline to compare against later.
--   2. staff_check_pancake_stock_snapshot re-fetches CURRENT stock for that same row's items and
--      compares it to the captured "before" - a super-user-only diagnostic, not a status change.
--
-- Existing rows (attempts made before this migration) have no "Stock Before Json" and so no
-- before/after comparison is possible for them - PO-0011's already-Failed rows fall in this
-- category, since a baseline can only be captured going forward.

alter table public."PurchaseOrder_Pancake_Purchases" add column if not exists "Stock Before Json" jsonb;

drop function if exists public._pancake_get_variation_warehouse_stock(text, text);

-- Returns current stock (remain_quantity) for one variation at one warehouse, or null if Pancake
-- could not be reached or the variation/warehouse was not found in the response - callers treat
-- null as "unknown", never as zero.
create or replace function public._pancake_get_variation_warehouse_stock(p_variation_id text, p_warehouse_id text)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_endpoint text;
  v_response extensions.http_response;
  v_body jsonb;
  v_vw jsonb;
  v_item jsonb;
begin
  if p_variation_id is null or trim(p_variation_id) = '' or p_warehouse_id is null or trim(p_warehouse_id) = '' then
    return null;
  end if;

  v_endpoint := v_base_url || '/shops/' || v_shop_id || '/variations/' || p_variation_id || '?api_key=' || v_api_key;

  begin
    -- Mirrors OnlinefunctionsEvents.GetCloudVariationDetailsForWarehouseAsync's own confirmed-working
    -- call shape against this exact endpoint: POST first (not a typo - Pancake accepts it here),
    -- falling back to GET only on 404/405.
    select * into v_response from extensions.http((
      'POST', v_endpoint, array[]::extensions.http_header[], 'application/json', ''
    )::extensions.http_request);

    if v_response.status = 404 or v_response.status = 405 then
      select * into v_response from extensions.http((
        'GET', v_endpoint, array[]::extensions.http_header[], null, null
      )::extensions.http_request);
    end if;

    if v_response.status < 200 or v_response.status >= 300 then
      return null;
    end if;

    v_body := v_response.content::jsonb;
  exception when others then
    return null;
  end;

  v_vw := coalesce(
    v_body -> 'variations_warehouses',
    v_body -> 'data' -> 'variations_warehouses',
    v_body -> 'variation' -> 'variations_warehouses'
  );
  if v_vw is null or jsonb_typeof(v_vw) <> 'array' then
    return null;
  end if;

  for v_item in select * from jsonb_array_elements(v_vw)
  loop
    if coalesce(v_item ->> 'warehouse_id', v_item ->> 'warehouseId', v_item ->> 'id') = p_warehouse_id then
      return coalesce(
        nullif(v_item ->> 'remain_quantity', '')::numeric,
        nullif(v_item ->> 'remainQuantity', '')::numeric,
        nullif(v_item ->> 'quantity', '')::numeric,
        nullif(v_item ->> 'qty', '')::numeric
      );
    end if;
  end loop;

  return null;
end;
$$;

drop function if exists public.staff_receive_purchase_order_lines(text, text, text, jsonb);

-- Identical to supabase_purchase_order_pancake_sync.sql's version except for the "Stock Before
-- Json" capture, inserted immediately before each warehouse group's Pancake POST attempt (marked
-- below).
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
  v_stock_before jsonb;
  v_seen_variation_ids text[];
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

    -- NEW: capture what Pancake currently shows for each distinct variation in this warehouse
    -- group BEFORE attempting the POST - the baseline staff_check_pancake_stock_snapshot compares
    -- against later if this attempt comes back Failed. Best-effort: a variation whose lookup fails
    -- just gets a null "quantity" here rather than blocking the actual receive.
    v_stock_before := '[]'::jsonb;
    v_seen_variation_ids := array[]::text[];
    for v_item in select value from jsonb_array_elements(v_wh_items)
    loop
      if not (v_item ->> 'variation_id' = any(v_seen_variation_ids)) then
        v_seen_variation_ids := v_seen_variation_ids || (v_item ->> 'variation_id');
        v_stock_before := v_stock_before || jsonb_build_object(
          'variation_id', v_item ->> 'variation_id',
          'quantity', public._pancake_get_variation_warehouse_stock(v_item ->> 'variation_id', v_wh)
        );
      end if;
    end loop;

    insert into public."PurchaseOrder_Pancake_Purchases" ("PONo", "WarehouseId", "WarehouseName", "Items Json", "ReceivedBy", "Stock Before Json")
    values (p_po_no, v_wh, v_wh_name, v_wh_items, p_admin_username, v_stock_before)
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
      -- retrying. staff_check_pancake_stock_snapshot is the manual follow-up for this case.
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

drop function if exists public.staff_check_pancake_stock_snapshot(text, text, bigint);

-- Super-user-only diagnostic for one Pancake Sync panel row (identified by its PurchaseEventNo):
-- re-fetches CURRENT stock for each item that attempt tried to push, and compares it against the
-- "Stock Before Json" baseline captured right before that attempt. Purely informational - this
-- never changes Sync Status or QtyReceived itself; use
-- staff_confirm_purchase_order_receipt_without_sync (supabase_purchase_order_manual_receive_confirm.sql)
-- for that, once the numbers here have made the judgement call clear.
create or replace function public.staff_check_pancake_stock_snapshot(
  p_admin_username text,
  p_admin_password text,
  p_purchase_event_no bigint
)
returns table(
  item_code text,
  variation_id text,
  warehouse_id text,
  warehouse_name text,
  quantity_expected numeric,
  quantity_before numeric,
  quantity_now numeric,
  quantity_delta numeric,
  likely_synced boolean
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row record;
  v_item jsonb;
  v_variation_id text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized - only a super user can check live Pancake stock.';
  end if;

  select * into v_row from public."PurchaseOrder_Pancake_Purchases" where "PurchaseEventNo" = p_purchase_event_no;
  if not found then
    raise exception 'Pancake sync attempt not found.';
  end if;

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');

  for v_item in select * from jsonb_array_elements(v_row."Items Json")
  loop
    v_variation_id := v_item ->> 'variation_id';

    quantity_expected := (v_item ->> 'quantity')::numeric;

    quantity_before := null;
    if v_row."Stock Before Json" is not null then
      select nullif(x ->> 'quantity', '')::numeric into quantity_before
      from jsonb_array_elements(v_row."Stock Before Json") x
      where x ->> 'variation_id' = v_variation_id
      limit 1;
    end if;

    quantity_now := public._pancake_get_variation_warehouse_stock(v_variation_id, v_row."WarehouseId");

    item_code := (select "Code" from public."Items" where "VariationId" = v_variation_id limit 1);
    variation_id := v_variation_id;
    warehouse_id := v_row."WarehouseId";
    warehouse_name := v_row."WarehouseName";
    quantity_delta := case when quantity_before is not null and quantity_now is not null then quantity_now - quantity_before else null end;
    -- A rough, not definitive, read: stock moved up by at least what this attempt was trying to
    -- add. Other stock movement (a sale, a different purchase) since the attempt can still make
    -- this wrong in either direction - it is a strong hint for the human decision, not a proof.
    likely_synced := case when quantity_delta is not null then quantity_delta >= quantity_expected else null end;
    return next;
  end loop;
end;
$$;

grant execute on function public.staff_check_pancake_stock_snapshot(text, text, bigint) to anon;

notify pgrst, 'reload schema';

-- Verification. Expect exactly one row per function.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'staff_receive_purchase_order_lines',
    'staff_check_pancake_stock_snapshot'
  )
order by p.proname, arguments;
