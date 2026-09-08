-- Receiving a Purchase Order now stocks in against the LINE'S OWN variant in Pancake, per
-- "question : lets say my PO is in BOX but my inventory is PC? once the PO is Receive will it
-- convert and update pancake as pcs?" -> "now on the PO the item has variant.. can we pull out the
-- variant field" -> "so are we certain that if we implement this once the PO is received the
-- variant will be updated to pancake?" -> "so can we push this?".
--
-- WHAT WAS WRONG. staff_receive_purchase_order_lines resolved the Pancake variation id from
-- Items."VariationId" - one REPRESENTATIVE variation per product, written by the catalog sync's
-- cross-link step (distinct on (item_code) ... order by variation_id desc, see
-- supabase_pancake_item_sku_match_fix.sql). Every line of a product receives against that one
-- variation today, regardless of which variant the line actually names. Receive 5 "Dowsil - Blue"
-- and 5 "Dowsil - Clear" on the same PO and both fives land on whichever variation happened to
-- sort last.
--
-- THE EVIDENCE THIS IS SAFE TO CHANGE (from supabase_diagnose_po_receive_variant_stock.sql,
-- query 5, run against this shop's own receiving history): PO-0007 has two 'Synced' rows sharing
-- ONE Pancake Purchase ID but carrying TWO DIFFERENT variation_id values. That is one real,
-- accepted POST /purchases call whose items array named two distinct variations and Pancake
-- validated and processed both under a single purchase. The fix below does not change the shape
-- of that call at all (still one items[] entry per line, still {quantity, variation_id, index}) -
-- it only changes WHICH variation id gets chosen for a line that has one of its own.
--
-- THE FIX. PurchaseOrderLines."VariantCode" (supabase_purchase_order_line_variant.sql) already IS
-- a Pancake VariationId - it is the exact value a variant picker on that line writes, sourced from
-- the same /products/variations feed that fills Items."VariationId" in the first place. So: use it
-- when the line has one, and keep today's Items."VariationId" fallback for a line that doesn't
-- (raised before variants existed, or ordered against the plain item on purpose).
--
-- Only the one lookup changes. Everything else in this ~200-line function - staging, warehouse
-- grouping, the HTTP call, the Synced/Rejected/Failed handling, the QtyReceived update - is
-- untouched, copied verbatim from supabase_purchase_order_pancake_sync.sql.

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

    -- THE CHANGE: the line's own variant first - the variant actually picked/ordered - falling
    -- back to the item's representative variation only when the line carries none. A blank
    -- VariantCode ('' rather than null) is treated the same as no variant, matching how every
    -- other reader of this column already guards it (e.g. staff_set_purchase_order_line_variant).
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

notify pgrst, 'reload schema';

-- Verification. Expect exactly one row.
select
  p.proname,
  pg_get_function_identity_arguments(p.oid) as arguments,
  has_function_privilege('anon', p.oid, 'EXECUTE') as has_anon_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname = 'staff_receive_purchase_order_lines';
