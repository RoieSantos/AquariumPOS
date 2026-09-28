-- Items added to an order in Pancake after it first synced never reached the portal's saved lines -
-- per "the new item i add is custom-stand but when I hit assign I cannot assign it to my stand maker"
-- (the order card showed the stand, because it reads lines live from Pancake, but the Assign section
-- didn't, because it reads public."OnlineOrderLines").
--
-- CAUSE: the every-minute cron_sync_online_orders_from_pancake re-reads an edited order in two passes.
-- The glass-thickness pass runs first, fetches the order from Pancake, and stamps NotePrintCheckedAt -
-- but only saved the glass thickness and print note, not the lines. The lines pass then saw
-- NotePrintCheckedAt newer than the order's Last_Updated_At and skipped it. So once an order had lines,
-- later edits to its items were never saved (for every non walk-in order).
--
-- FIX: the glass pass now also saves the lines it already fetched (same mapping as the lines pass), and
-- removes lines deleted in Pancake. No extra Pancake calls.
--
-- Run AFTER supabase_online_order_balance_local_calc.sql (a copy of its cron function with only this
-- change). Step 2 re-reads open orders that are already out of date.

create or replace function public.cron_sync_online_orders_from_pancake(
  p_max_pages int default 100,
  p_page_size int default 100,
  p_max_glass_detail_calls int default 30,
  p_max_lines_detail_calls int default 30
)
returns table(orders_synced int, orders_inserted int, orders_updated int, glass_checked int, lines_checked int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_page_size int := least(greatest(coalesce(p_page_size, 100), 1), 200);
  -- Raised from 20/50 to 100/300 (per "fix 2"): the shop's order backlog exceeds 2,000 rows
  -- (20 pages x 100/page), so every run was hitting the old page cap before ever reaching a
  -- short/empty page - meaning v_reached_end never became true and PancakeSyncState never
  -- advanced, even though orders were genuinely being synced every 5 minutes. At ~0.5s/page
  -- (observed from cron.job_run_details), 100 pages is ~50s and 300 pages is ~2.5min - both
  -- comfortably inside the 5-minute schedule interval.
  v_max_pages int := least(greatest(coalesce(p_max_pages, 100), 1), 300);
  -- See the "GLASS THICKNESS BACKFILL" header comment above for why this is capped instead of
  -- checking every unchecked order in one run.
  v_max_glass_detail_calls int := least(greatest(coalesce(p_max_glass_detail_calls, 30), 0), 200);
  v_glass_order_id text;
  v_glass_detail_url text;
  v_glass_detail_response extensions.http_response;
  v_glass_detail_body jsonb;
  v_glass_order_el jsonb;
  v_glass_line_items jsonb;
  v_glass_line_item jsonb;
  v_glass_variation_id text;
  v_glass_qty numeric;
  v_glass_price numeric;
  v_glass_line_id text;
  v_glass_seen text[];
  v_glass_variation_info jsonb;
  v_glass_product_display_id text;
  v_glass_line_name text;
  v_glass_line_note text;
  v_glass_has_12mm boolean;
  v_glass_has_10mm boolean;
  v_glass_thickness text;
  v_glass_checked int := 0;
  v_max_lines_detail_calls int := least(greatest(coalesce(p_max_lines_detail_calls, 30), 0), 200);
  v_lines_order_id text;
  v_lines_detail_url text;
  v_lines_detail_response extensions.http_response;
  v_lines_detail_body jsonb;
  v_lines_order_el jsonb;
  v_lines_items jsonb;
  v_lines_item jsonb;
  v_lines_variation_info jsonb;
  v_lines_product_display_id text;
  v_lines_variation_id text;
  v_lines_qty numeric;
  v_lines_price numeric;
  v_lines_name text;
  v_lines_note text;
  v_lines_line_id text;
  v_lines_checked int := 0;
  v_last_sync_utc timestamptz;
  v_since_qs text := '';
  v_iso text;
  v_page int;
  v_url text;
  v_response extensions.http_response;
  v_body jsonb;
  v_items jsonb;
  v_item jsonb;
  v_items_this_page int;
  v_reached_end boolean := false;
  v_order_id text;
  v_rec_flag text;
  v_received_at_shop boolean;
  v_status_raw text;
  v_status text;
  v_customer text;
  v_created_raw text;
  v_created_utc timestamptz;
  v_date date;
  v_time text;
  v_page_id text;
  v_conversation_id text;
  v_location_id text;
  v_money_raw text;
  v_money_to_collect numeric;
  v_prepaid_raw text;
  v_amount_paid numeric;
  v_cod_raw text;
  v_balance numeric;
  v_discount_raw text;
  v_discount numeric;
  v_delivery_fee_raw text;
  v_delivery_fee numeric;
  v_last_paid_raw text;
  v_last_paid_utc timestamptz;
  v_last_paid_date date;
  v_last_paid_time text;
  v_last_updated_raw text;
  v_last_updated_utc timestamptz;
  v_max_last_updated_seen timestamptz;
  v_converted_last_updated_date date;
  v_for_delivery_kind text;
  v_for_delivery boolean;
  v_shipping_address text;
  v_shipping_phone text;
  v_est_delivery_raw text;
  v_est_delivery_date date;
  v_created_by text;
  v_confirmed_by text;
  v_confirmed_at timestamptz;
  v_was_existing boolean;
  v_orders_synced int := 0;
  v_orders_inserted int := 0;
  v_orders_updated int := 0;
  v_max_run_utc timestamptz := now();
  -- Pancake's internal print note - only present on the DETAIL response, so opportunistically
  -- extracted from whichever backfill loop below already paid for a detail fetch (glass or
  -- lines) - see the OnlineOrders."NotePrint" column comment in supabase_orders_sync_tables.sql.
  -- Both loops' WHERE clauses are widened to also pick up "NotePrintCheckedAt is null" so every
  -- order eventually gets checked even if it already has GlassThicknessCheckedAt/lines from
  -- before this column existed.
  v_note_print text;
begin
  -- No auth check here - see the header comment above for why (internal, pg_cron-only caller).

  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');

  select "LastSyncUtc" into v_last_sync_utc from public."PancakeSyncState" where "Entity" = '/orders';

  if v_last_sync_utc is not null then
    v_iso := to_char(v_last_sync_utc at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
    v_since_qs := '&updated_after=' || v_iso || '&updatedAfter=' || v_iso
      || '&created_after=' || v_iso || '&createdAfter=' || v_iso || '&since=' || v_iso;
  end if;

  for v_page in 1..v_max_pages loop
    v_url := v_base_url || '/shops/' || v_shop_id || '/orders?api_key=' || v_api_key
      || '&page_size=' || v_page_size || '&page=' || v_page || v_since_qs;

    v_response := extensions.http_get(v_url);
    if v_response.status < 200 or v_response.status >= 300 then
      raise exception 'Pancake orders request failed (HTTP %) on page %.', v_response.status, v_page;
    end if;

    v_body := v_response.content::jsonb;

    v_items := case
      when jsonb_typeof(v_body) = 'array' then v_body
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'data') = 'array' then v_body -> 'data'
      when jsonb_typeof(v_body) = 'object' and jsonb_typeof(v_body -> 'orders') = 'array' then v_body -> 'orders'
      else '[]'::jsonb
    end;

    v_items_this_page := jsonb_array_length(v_items);
    if v_items_this_page = 0 then
      v_reached_end := true;
      exit;
    end if;

    for v_item in select * from jsonb_array_elements(v_items)
    loop
      begin
        v_rec_flag := coalesce(v_item ->> 'received_at_shop', v_item ->> 'receivedAtShop');
        v_received_at_shop := lower(coalesce(trim(v_rec_flag), '')) = 'true';
        if lower(coalesce(trim(v_rec_flag), '')) not in ('true', 'false') then
          continue;
        end if;

        v_order_id := coalesce(
          v_item ->> 'receipt_no', v_item ->> 'receiptNo', v_item ->> 'receipt',
          v_item ->> 'id', v_item ->> 'order_number', v_item ->> 'number'
        );
        if v_order_id is null or trim(v_order_id) = '' then
          continue;
        end if;

        v_status_raw := coalesce(v_item ->> 'status_name', v_item ->> 'status', v_item ->> 'state', v_item ->> 'order_status');
        if lower(trim(coalesce(v_status_raw, ''))) = 'new' then
          continue;
        end if;

        v_last_updated_raw := coalesce(v_item ->> 'updated_at', v_item ->> 'updatedAt', v_item ->> 'last_updated_at', v_item ->> 'lastUpdatedAt');
        v_last_updated_utc := public.pancake_try_parse_timestamptz(v_last_updated_raw);

        -- Track the newest last_updated_at Pancake actually returned this run, regardless of
        -- whether the p_max_pages safety cap is hit before the walk reaches its true end - this
        -- becomes the new cursor below (instead of "now()" gated behind v_reached_end), so
        -- PancakeSyncState always makes forward progress every single run, even a partial one.
        if v_last_updated_utc is not null and (v_max_last_updated_seen is null or v_last_updated_utc > v_max_last_updated_seen) then
          v_max_last_updated_seen := v_last_updated_utc;
        end if;

        if v_last_sync_utc is not null and v_last_updated_utc is not null and v_last_updated_utc <= v_last_sync_utc then
          continue;
        end if;

        v_status := case lower(trim(v_status_raw))
          when 'submitted' then 'Confirmed'
          when 'packing' then 'To Ship'
          when 'packed' then 'To Ship'
          when 'pending' then 'Pending Transfer'
          when '9' then 'Pending Transfer'
          when 'pending_transfer' then 'Pending Transfer'
          when 'pending transfer' then 'Pending Transfer'
          when 'waiting_for_pickup' then 'Pending Transfer'
          when 'waiting for pickup' then 'Pending Transfer'
          when '12' then 'In-Transit'
          when 'wait_print' then 'In-Transit'
          when 'wait print' then 'In-Transit'
          when 'in_transit' then 'In-Transit'
          when 'in-transit' then 'In-Transit'
          when 'shipped' then 'Shipped'
          when 'delivered' then 'Shipped'
          when '2' then 'Shipped'
          when 'received' then 'Received'
          when '3' then 'Received'
          when 'printed' then 'Printed'
          else v_status_raw
        end;

        v_customer := coalesce(
          v_item -> 'customer' ->> 'name', v_item -> 'customer' ->> 'customer_name', v_item -> 'customer' ->> 'full_name',
          v_item ->> 'customer_name', v_item ->> 'customer', v_item ->> 'client_name', v_item ->> 'buyer_name'
        );

        v_created_raw := coalesce(v_item ->> 'inserted_at', v_item ->> 'insertedAt', v_item ->> 'created_at', v_item ->> 'createdAt', v_item ->> 'date', v_item ->> 'created');
        v_created_utc := public.pancake_try_parse_timestamptz(v_created_raw);
        if v_created_utc is not null then
          v_date := (v_created_utc at time zone 'Asia/Manila')::date;
          v_time := to_char(v_created_utc at time zone 'Asia/Manila', 'HH24:MI:SS');
        else
          v_date := null;
          v_time := null;
        end if;

        v_page_id := coalesce(v_item ->> 'page_id', v_item ->> 'pageId', v_item ->> 'page');
        v_conversation_id := coalesce(v_item ->> 'conversation_id', v_item ->> 'conversationId', v_item ->> 'conversation', v_item ->> 'thread_id', v_item ->> 'threadId');
        v_location_id := coalesce(v_item ->> 'warehouse_id', v_item ->> 'warehouseId');

        v_money_raw := coalesce(
          v_item -> 'money_to_collect' ->> 'amount', v_item -> 'money_to_collect' ->> 'value', v_item -> 'money_to_collect' ->> 'total',
          v_item ->> 'money_to_collect', v_item ->> 'moneyToCollect', v_item ->> 'total_price', v_item ->> 'total', v_item ->> 'amount', v_item ->> 'money'
        );
        v_money_to_collect := public.pancake_parse_decimal(v_money_raw);

        v_prepaid_raw := coalesce(
          v_item -> 'prepaid' ->> 'amount', v_item -> 'prepaid' ->> 'value',
          v_item ->> 'prepaid', v_item ->> 'prepaid_amount', v_item ->> 'pre_paid', v_item ->> 'deposit', v_item ->> 'prepayment'
        );
        v_amount_paid := public.pancake_parse_decimal(v_prepaid_raw);

        -- Balance used to be read straight from Pancake's own "cod" field here (v_cod_raw :=
        -- coalesce(cod, cash_on_delivery, balance, due, amount_due)). That goes stale whenever a
        -- payment or order edit updates money_to_collect/prepaid without Pancake also recomputing
        -- cod - which is exactly what was causing the automated To-Ship Messenger reply to quote a
        -- wrong balance to customers. Computed locally instead from the two fields that ARE kept in
        -- sync on every pull (confirmed against a real order: MoneyToCollect 17564.19, AmountPaid
        -- 10000.00 -> Balance 7564.19 - see supabase_manual_insert_online_order_91120.sql).
        v_balance := v_money_to_collect - v_amount_paid;

        v_discount_raw := coalesce(v_item ->> 'discount', v_item ->> 'discount_amount', v_item ->> 'discounted_amount');
        v_discount := public.pancake_parse_decimal(v_discount_raw);

        v_delivery_fee_raw := coalesce(
          v_item -> 'shipping_fee' ->> 'amount', v_item -> 'shipping_fee' ->> 'value',
          v_item ->> 'shipping_fee', v_item ->> 'shippingFee', v_item ->> 'delivery_fee', v_item ->> 'deliveryFee'
        );
        v_delivery_fee := public.pancake_parse_decimal(v_delivery_fee_raw);

        v_last_paid_raw := coalesce(v_item ->> 'last_paid_at', v_item ->> 'lastPaidAt', v_item ->> 'last_payment', v_item ->> 'last_paid', v_item ->> 'last_payment_at');
        v_last_paid_utc := public.pancake_try_parse_timestamptz(v_last_paid_raw);
        if v_last_paid_utc is not null then
          v_last_paid_date := (v_last_paid_utc at time zone 'Asia/Manila')::date;
          v_last_paid_time := to_char(v_last_paid_utc at time zone 'Asia/Manila', 'HH24:MI:SS');
        elsif v_amount_paid > 0 and v_date is not null then
          v_last_paid_date := v_date;
          v_last_paid_time := v_time;
        else
          v_last_paid_date := null;
          v_last_paid_time := null;
        end if;

        v_converted_last_updated_date := case when v_last_updated_utc is not null then (v_last_updated_utc at time zone 'Asia/Manila')::date else null end;

        v_for_delivery_kind := jsonb_typeof(v_item -> 'is_free_shipping');
        v_for_delivery := case v_for_delivery_kind
          when 'boolean' then (v_item ->> 'is_free_shipping')::boolean
          when 'number' then (v_item ->> 'is_free_shipping')::numeric <> 0
          when 'string' then lower(trim(v_item ->> 'is_free_shipping')) in ('true', 'yes', 'y', 'on', '1')
          else false
        end;

        v_shipping_address := coalesce(
          v_item -> 'shipping_address' ->> 'full_address', v_item -> 'shipping_address' ->> 'fullAddress',
          v_item -> 'shipping_address' ->> 'address', v_item -> 'shipping_address' ->> 'formatted_address', v_item -> 'shipping_address' ->> 'formattedAddress',
          v_item ->> 'shipping_address_full', v_item ->> 'shippingAddressFull', v_item ->> 'full_address', v_item ->> 'fullAddress'
        );

        v_shipping_phone := coalesce(
          v_item -> 'shipping_address' ->> 'phone_number', v_item -> 'shipping_address' ->> 'phoneNumber',
          v_item ->> 'phone_number', v_item ->> 'bill_phone_number', v_item -> 'customer' ->> 'phone_number', v_item -> 'customer' ->> 'phone'
        );

        v_est_delivery_raw := coalesce(
          v_item -> 'estimate_delivery_date' ->> 'new', v_item ->> 'estimate_delivery_date',
          v_item -> 'estimated_delivery_date' ->> 'new', v_item ->> 'estimated_delivery_date',
          v_item ->> 'estimatedDeliveryDate', v_item ->> 'delivery_date', v_item ->> 'deliveryDate'
        );
        v_est_delivery_date := case
          when v_est_delivery_raw is null then null
          when v_est_delivery_raw ~ '^\d{4}-\d{2}-\d{2}$' then v_est_delivery_raw::date
          else (public.pancake_try_parse_timestamptz(v_est_delivery_raw) at time zone 'Asia/Manila')::date
        end;

        select t.created_by, t.confirmed_by, t.confirmed_at into v_created_by, v_confirmed_by, v_confirmed_at
        from public.pancake_extract_created_confirmed_by(v_item) t;

        select exists(select 1 from public."OnlineOrders" where "OrderID" = v_order_id) into v_was_existing;

        insert into public."OnlineOrders" (
          "OrderID", "Date", "Time", "Status", "CustomerName", "Page_ID", "Conversation_ID", "LocationID",
          "MoneyToCollect", "AmountPaid", "Discount", "DeliveryFee", "Balance", "ForDelivery", "ShippingAddress", "ShippingPhone",
          "EstimatedDeliveryDate", "Last_Updated_At", "Converted_LastUpdated_At", "LastPaid_Date", "LastPaid_Time", "ReceivedAtShop",
          "CreatedBy", "ConfirmedBy", "ConfirmedAtUtc", "SyncedAtUtc"
        ) values (
          v_order_id, v_date, v_time, v_status, v_customer, v_page_id, v_conversation_id, v_location_id,
          v_money_to_collect, v_amount_paid, v_discount, v_delivery_fee, v_balance, v_for_delivery, v_shipping_address, v_shipping_phone,
          v_est_delivery_date, v_last_updated_utc, v_converted_last_updated_date, v_last_paid_date, v_last_paid_time, v_received_at_shop,
          v_created_by, v_confirmed_by, v_confirmed_at, now()
        )
        on conflict ("OrderID") do update set
          "Date" = excluded."Date",
          "Time" = excluded."Time",
          "Status" = excluded."Status",
          "CustomerName" = excluded."CustomerName",
          "Page_ID" = excluded."Page_ID",
          "Conversation_ID" = excluded."Conversation_ID",
          "LocationID" = excluded."LocationID",
          "MoneyToCollect" = excluded."MoneyToCollect",
          "AmountPaid" = excluded."AmountPaid",
          "Discount" = excluded."Discount",
          "DeliveryFee" = excluded."DeliveryFee",
          "Balance" = excluded."Balance",
          "ForDelivery" = excluded."ForDelivery",
          "ShippingAddress" = excluded."ShippingAddress",
          "ShippingPhone" = excluded."ShippingPhone",
          "EstimatedDeliveryDate" = excluded."EstimatedDeliveryDate",
          "Last_Updated_At" = excluded."Last_Updated_At",
          "Converted_LastUpdated_At" = excluded."Converted_LastUpdated_At",
          "LastPaid_Date" = excluded."LastPaid_Date",
          "LastPaid_Time" = excluded."LastPaid_Time",
          "ReceivedAtShop" = excluded."ReceivedAtShop",
          "CreatedBy" = coalesce(excluded."CreatedBy", "OnlineOrders"."CreatedBy"),
          "ConfirmedBy" = coalesce(excluded."ConfirmedBy", "OnlineOrders"."ConfirmedBy"),
          "ConfirmedAtUtc" = coalesce(excluded."ConfirmedAtUtc", "OnlineOrders"."ConfirmedAtUtc"),
          "SyncedAtUtc" = now();

        v_orders_synced := v_orders_synced + 1;
        if v_was_existing then
          v_orders_updated := v_orders_updated + 1;
        else
          v_orders_inserted := v_orders_inserted + 1;
        end if;
      exception when others then
        null; -- skip malformed order, keep processing the rest
      end;
    end loop;

    if v_items_this_page < v_page_size then
      v_reached_end := true;
      exit;
    end if;
  end loop;

  -- Advance the cursor to the newest last_updated_at Pancake actually returned this run - NOT
  -- "now()", and NOT gated behind ever reaching the true end/p_max_pages cap. This guarantees
  -- forward progress on every single run: even a run that hits the page cap partway through a
  -- large backlog still moves PancakeSyncState ahead to what it genuinely saw, so the very next
  -- 5-minute run resumes from there instead of restarting from page 1 every time. Only falls
  -- back to v_max_run_utc ('now') when a run saw literally no last_updated_at values at all AND
  -- fully reached the end (a genuinely caught-up, empty result) - never on a page-cap cutoff.
  if v_max_last_updated_seen is not null then
    insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
    values ('/orders', v_max_last_updated_seen)
    on conflict ("Entity") do update
      set "LastSyncUtc" = excluded."LastSyncUtc"
      where public."PancakeSyncState"."LastSyncUtc" is null
         or excluded."LastSyncUtc" > public."PancakeSyncState"."LastSyncUtc";
  elsif v_reached_end then
    insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
    values ('/orders', v_max_run_utc)
    on conflict ("Entity") do update
      set "LastSyncUtc" = excluded."LastSyncUtc"
      where public."PancakeSyncState"."LastSyncUtc" is null
         or excluded."LastSyncUtc" > public."PancakeSyncState"."LastSyncUtc";
  end if;

  -- GLASS THICKNESS BACKFILL - see the header comment above. Runs after the header sync/cursor
  -- advance so a slow Pancake response here can never block the header sync's own progress.
  if v_max_glass_detail_calls > 0 then
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

    for v_glass_order_id in
      select "OrderID" from public."OnlineOrders"
      where (
        "GlassThicknessCheckedAt" is null
        or "NotePrintCheckedAt" is null
        -- Per direct request: "compute once, cache forever" was silently missing a NotePrint
        -- edited in Pancake AFTER the one-time check already ran (confirmed on a real order -
        -- checked once, cached null forever, even though Pancake's own note_print was edited
        -- days later). Re-qualifies an already-checked order once Pancake's own Last_Updated_At
        -- moves past whichever check timestamp is older, so a later edit gets picked back up on
        -- this cron's very next pass instead of needing a manual reset
        -- (supabase_reset_note_print_check_76357.sql) every time.
        or ("Last_Updated_At" is not null and (
          "Last_Updated_At" > "GlassThicknessCheckedAt" or "Last_Updated_At" > "NotePrintCheckedAt"
        ))
      )
        and coalesce("ReceivedAtShop", false) is not true
      order by "Last_Updated_At" desc nulls last
      limit v_max_glass_detail_calls
    loop
      begin
        v_glass_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_glass_order_id || '?api_key=' || v_api_key || '&page_size=1000';
        v_glass_detail_response := extensions.http_get(v_glass_detail_url);

        if v_glass_detail_response.status < 200 or v_glass_detail_response.status >= 300 then
          continue; -- leave GlassThicknessCheckedAt null - retried on a future run
        end if;

        v_glass_detail_body := v_glass_detail_response.content::jsonb;
        v_glass_order_el := case
          when jsonb_typeof(v_glass_detail_body -> 'data') = 'object' then v_glass_detail_body -> 'data'
          when jsonb_typeof(v_glass_detail_body) = 'object' then v_glass_detail_body
          else null
        end;
        v_glass_line_items := case
          when v_glass_order_el is not null and jsonb_typeof(v_glass_order_el -> 'items') = 'array' then v_glass_order_el -> 'items'
          else '[]'::jsonb
        end;

        v_glass_has_12mm := false;
        v_glass_has_10mm := false;
        v_glass_seen := array[]::text[];

        for v_glass_line_item in select * from jsonb_array_elements(v_glass_line_items)
        loop
          v_glass_variation_info := v_glass_line_item -> 'variation_info';
          v_glass_product_display_id := coalesce(v_glass_variation_info ->> 'product_display_id', v_glass_line_item ->> 'product_display_id');
          v_glass_line_name := coalesce(v_glass_variation_info ->> 'name', v_glass_line_item ->> 'name');
          v_glass_line_note := v_glass_line_item ->> 'note';

          if regexp_replace(coalesce(v_glass_line_name, '') || ' ' || coalesce(v_glass_line_note, '') || ' ' || coalesce(v_glass_product_display_id, ''), '\s+', '', 'g') ilike '%12mm%' then
            v_glass_has_12mm := true;
          elsif regexp_replace(coalesce(v_glass_line_name, '') || ' ' || coalesce(v_glass_line_note, '') || ' ' || coalesce(v_glass_product_display_id, ''), '\s+', '', 'g') ilike '%10mm%' then
            v_glass_has_10mm := true;
          end if;

          -- Save the line too (supabase_online_order_sync_edited_lines.sql): this pass marks the order
          -- checked, which made the lines pass below skip it, so items added in Pancake later never
          -- reached OnlineOrderLines. Same mapping as the lines pass.
          if v_glass_product_display_id is not null and trim(v_glass_product_display_id) <> '' then
            begin
              v_glass_variation_id := coalesce(v_glass_variation_info ->> 'variation_id', v_glass_line_item ->> 'variation_id', v_glass_line_item ->> 'variationId');
              v_glass_qty := public.pancake_parse_decimal(v_glass_line_item ->> 'quantity');
              v_glass_price := public.pancake_parse_decimal(coalesce(v_glass_variation_info ->> 'retail_price', v_glass_line_item ->> 'retail_price'));
              v_glass_line_id := coalesce(
                v_glass_line_item ->> 'line_id', v_glass_line_item ->> 'id', v_glass_line_item ->> 'order_line_id',
                v_glass_line_item ->> 'order_item_id', v_glass_line_item ->> 'item_id', ''
              );

              insert into public."OnlineOrderLines" (
                "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "GrossAmount", "Note", "Description", "SyncedAtUtc"
              ) values (
                v_glass_order_id, v_glass_line_id, v_glass_product_display_id, v_glass_product_display_id, nullif(v_glass_variation_id, ''), v_glass_qty, null, v_glass_price, v_glass_price * v_glass_qty, nullif(v_glass_line_note, ''), nullif(v_glass_line_name, ''), now()
              )
              on conflict ("OrderID", "LineID") do update set
                "ItemCode" = excluded."ItemCode",
                "product_display_id" = excluded."product_display_id",
                "VariationId" = excluded."VariationId",
                "Quantity" = excluded."Quantity",
                "Price" = excluded."Price",
                "GrossAmount" = excluded."GrossAmount",
                "Note" = excluded."Note",
                "Description" = excluded."Description",
                "SyncedAtUtc" = now();

              v_glass_seen := array_append(v_glass_seen, v_glass_line_id);
            exception when others then
              null; -- skip malformed line, keep processing the rest
            end;
          end if;
        end loop;

        -- Lines removed in Pancake are removed here too - only when Pancake returned at least one
        -- line, so an empty/bad response never wipes an order's lines.
        if cardinality(v_glass_seen) > 0 then
          delete from public."OnlineOrderLines" l
          where l."OrderID" = v_glass_order_id and not (l."LineID" = any(v_glass_seen));
        end if;

        v_glass_thickness := case when v_glass_has_12mm then '12mm' when v_glass_has_10mm then '10mm' else null end;
        v_note_print := nullif(trim(coalesce(v_glass_order_el ->> 'note_print', v_glass_order_el ->> 'notePrint', '')), '');

        update public."OnlineOrders"
          set "GlassThickness" = v_glass_thickness, "GlassThicknessCheckedAt" = now(),
              "NotePrint" = coalesce(v_note_print, "NotePrint"), "NotePrintCheckedAt" = now()
          where "OrderID" = v_glass_order_id;

        v_glass_checked := v_glass_checked + 1;
      exception when others then
        null; -- skip this order's glass check, retried on a future run
      end;
    end loop;
  end if;

  -- ORDER LINES BACKFILL - see the header comment above. Runs after the glass thickness pass so
  -- neither can block the other's progress; each order costs one extra Pancake detail call,
  -- same as the glass check, but is not filtered to ReceivedAtShop = false.
  if v_max_lines_detail_calls > 0 then
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

    for v_lines_order_id in
      select o."OrderID" from public."OnlineOrders" o
      where not exists (select 1 from public."OnlineOrderLines" l where l."OrderID" = o."OrderID")
         or o."NotePrintCheckedAt" is null
         -- Same re-check-on-later-edit fix as the glass thickness loop above - see its comment.
         or (o."Last_Updated_At" is not null and o."Last_Updated_At" > o."NotePrintCheckedAt")
      order by o."Last_Updated_At" desc nulls last
      limit v_max_lines_detail_calls
    loop
      begin
        v_lines_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_lines_order_id || '?api_key=' || v_api_key || '&page_size=1000';
        v_lines_detail_response := extensions.http_get(v_lines_detail_url);

        if v_lines_detail_response.status < 200 or v_lines_detail_response.status >= 300 then
          continue; -- no OnlineOrderLines rows written - retried on a future run
        end if;

        v_lines_detail_body := v_lines_detail_response.content::jsonb;
        v_lines_order_el := case
          when jsonb_typeof(v_lines_detail_body -> 'data') = 'object' then v_lines_detail_body -> 'data'
          when jsonb_typeof(v_lines_detail_body) = 'object' then v_lines_detail_body
          else null
        end;
        v_lines_items := case
          when v_lines_order_el is not null and jsonb_typeof(v_lines_order_el -> 'items') = 'array' then v_lines_order_el -> 'items'
          else '[]'::jsonb
        end;

        for v_lines_item in select * from jsonb_array_elements(v_lines_items)
        loop
          begin
            v_lines_variation_info := v_lines_item -> 'variation_info';
            v_lines_product_display_id := coalesce(v_lines_variation_info ->> 'product_display_id', v_lines_item ->> 'product_display_id');
            if v_lines_product_display_id is null or trim(v_lines_product_display_id) = '' then
              continue;
            end if;

            v_lines_variation_id := coalesce(v_lines_variation_info ->> 'variation_id', v_lines_item ->> 'variation_id', v_lines_item ->> 'variationId');
            v_lines_qty := public.pancake_parse_decimal(v_lines_item ->> 'quantity');
            v_lines_price := public.pancake_parse_decimal(coalesce(v_lines_variation_info ->> 'retail_price', v_lines_item ->> 'retail_price'));
            v_lines_name := coalesce(v_lines_variation_info ->> 'name', v_lines_item ->> 'name');
            v_lines_note := v_lines_item ->> 'note';
            v_lines_line_id := coalesce(
              v_lines_item ->> 'line_id', v_lines_item ->> 'id', v_lines_item ->> 'order_line_id',
              v_lines_item ->> 'order_item_id', v_lines_item ->> 'item_id', ''
            );

            insert into public."OnlineOrderLines" (
              "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "GrossAmount", "Note", "Description", "SyncedAtUtc"
            ) values (
              v_lines_order_id, v_lines_line_id, v_lines_product_display_id, v_lines_product_display_id, nullif(v_lines_variation_id, ''), v_lines_qty, null, v_lines_price, v_lines_price * v_lines_qty, nullif(v_lines_note, ''), nullif(v_lines_name, ''), now()
            )
            on conflict ("OrderID", "LineID") do update set
              "ItemCode" = excluded."ItemCode",
              "product_display_id" = excluded."product_display_id",
              "VariationId" = excluded."VariationId",
              "Quantity" = excluded."Quantity",
              "Price" = excluded."Price",
              "GrossAmount" = excluded."GrossAmount",
              "Note" = excluded."Note",
              "Description" = excluded."Description",
              "SyncedAtUtc" = now();
          exception when others then
            null; -- skip malformed line, keep processing the rest
          end;
        end loop;

        v_note_print := nullif(trim(coalesce(v_lines_order_el ->> 'note_print', v_lines_order_el ->> 'notePrint', '')), '');
        update public."OnlineOrders"
          set "NotePrint" = coalesce(v_note_print, "NotePrint"), "NotePrintCheckedAt" = now()
          where "OrderID" = v_lines_order_id;

        v_lines_checked := v_lines_checked + 1;
      exception when others then
        null; -- skip this order's lines fetch, retried on a future run
      end;
    end loop;
  end if;

  return query select v_orders_synced, v_orders_inserted, v_orders_updated, v_glass_checked, v_lines_checked;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Re-check open orders (not shipped/received/cancelled) on the next cron runs, 30 per minute, so
--    items already added in Pancake get saved now. Touches only the check timestamp.
update public."OnlineOrders"
set "GlassThicknessCheckedAt" = null
where coalesce("ReceivedAtShop", false) is not true
  and lower(trim(coalesce("Status", ''))) not in ('shipped', 'delivered', '2', 'received', '3', 'canceled', 'cancelled');
