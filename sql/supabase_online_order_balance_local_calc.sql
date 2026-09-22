-- Fixes the Online Orders "Balance" field being sometimes wrong in the automated "To Ship"
-- Messenger reply (the message sent through Pancake when staff mark an order To Ship from either
-- the desktop app or the portal - see _send_online_order_status_message in
-- supabase_online_order_portal_status_update.sql, which just prints whatever is in
-- OnlineOrders."Balance" at that moment).
--
-- ROOT CAUSE: the three functions below (the only writers of OnlineOrders."Balance" - manual
-- sync, the 1-minute cron sync, and the live-browse auto-persist) all read Balance straight from
-- Pancake's own "cod" field instead of computing it from MoneyToCollect/AmountPaid, which ARE
-- both correctly kept in sync on every pull. Pancake's cod field goes stale whenever a payment or
-- an order edit updates money_to_collect/prepaid without Pancake also recomputing cod, so the
-- automated message ends up quoting a wrong (usually stale/too-high) balance to the customer.
--
-- FIX: Balance is now computed locally as MoneyToCollect - AmountPaid, dropping the cod field
-- entirely. Confirmed correct against a real order (supabase_manual_insert_online_order_91120.sql):
-- MoneyToCollect 17564.19, AmountPaid 10000.00 -> Balance 7564.19, i.e. Discount is NOT subtracted
-- again here - money_to_collect from Pancake already reflects the discount.
--
-- Run this AFTER supabase_pancake_manual_sync.sql (the version this redefines) - it's a verbatim
-- copy of admin_sync_online_orders_from_pancake / cron_sync_online_orders_from_pancake /
-- admin_list_online_orders_live from that file with only the Balance line changed in each. Also
-- backfills every already-synced order's Balance below, so existing wrong values are corrected
-- immediately instead of waiting for each order's next sync touch.

create or replace function public.admin_sync_online_orders_from_pancake(
  p_admin_username text,
  p_admin_password text,
  p_max_pages int default 5,
  p_page_size int default 100
)
returns table(orders_synced int, orders_inserted int, orders_updated int, lines_synced int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_page_size int := least(greatest(coalesce(p_page_size, 100), 1), 200);
  v_max_pages int := least(greatest(coalesce(p_max_pages, 5), 1), 50);
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
  v_lines_synced int := 0;
  v_max_run_utc timestamptz := now();
  -- Order lines (detail fetch per order)
  v_detail_url text;
  v_detail_response extensions.http_response;
  v_detail_body jsonb;
  v_order_el jsonb;
  v_line_items jsonb;
  v_line_item jsonb;
  v_variation_info jsonb;
  v_product_display_id text;
  v_variation_id text;
  v_qty numeric;
  v_price numeric;
  v_line_name text;
  v_line_note text;
  v_line_id text;
  -- Glass thickness detection (per-order, reset before each order's line-item loop) - this
  -- function already pays for a full per-order detail fetch to get lines, so persisting the
  -- glass flag here too is free; see the GlassThickness column comment in
  -- supabase_orders_sync_tables.sql for the full detection/caching design.
  v_glass_has_12mm boolean;
  v_glass_has_10mm boolean;
  v_glass_thickness text;
  -- Pancake's internal print note - only present on the DETAIL response, so extracted alongside
  -- glass thickness right after the same per-order detail fetch (see the OnlineOrders."NotePrint"
  -- column comment in supabase_orders_sync_tables.sql).
  v_note_print text;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

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
    exit when v_items_this_page = 0;

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

        -- Order lines: one extra HTTP call per order (mirrors IntegrationEvents.FetchOrderLinesAsync).
        begin
          v_detail_url := v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order_id || '?api_key=' || v_api_key || '&page_size=1000';
          v_detail_response := extensions.http_get(v_detail_url);

          if v_detail_response.status >= 200 and v_detail_response.status < 300 then
            v_detail_body := v_detail_response.content::jsonb;
            v_order_el := case
              when jsonb_typeof(v_detail_body -> 'data') = 'object' then v_detail_body -> 'data'
              when jsonb_typeof(v_detail_body) = 'object' then v_detail_body
              else null
            end;
            v_line_items := case
              when v_order_el is not null and jsonb_typeof(v_order_el -> 'items') = 'array' then v_order_el -> 'items'
              else '[]'::jsonb
            end;
            v_glass_has_12mm := false;
            v_glass_has_10mm := false;

            for v_line_item in select * from jsonb_array_elements(v_line_items)
            loop
              begin
                v_variation_info := v_line_item -> 'variation_info';
                v_product_display_id := coalesce(v_variation_info ->> 'product_display_id', v_line_item ->> 'product_display_id');
                if v_product_display_id is null or trim(v_product_display_id) = '' then
                  continue;
                end if;

                v_variation_id := coalesce(v_variation_info ->> 'variation_id', v_line_item ->> 'variation_id', v_line_item ->> 'variationId');
                v_qty := public.pancake_parse_decimal(v_line_item ->> 'quantity');
                v_price := public.pancake_parse_decimal(coalesce(v_variation_info ->> 'retail_price', v_line_item ->> 'retail_price'));
                v_line_name := coalesce(v_variation_info ->> 'name', v_line_item ->> 'name');
                v_line_note := v_line_item ->> 'note';
                v_line_id := coalesce(
                  v_line_item ->> 'line_id', v_line_item ->> 'id', v_line_item ->> 'order_line_id',
                  v_line_item ->> 'order_item_id', v_line_item ->> 'item_id', ''
                );

                if regexp_replace(coalesce(v_line_name, '') || ' ' || coalesce(v_line_note, '') || ' ' || coalesce(v_product_display_id, ''), '\s+', '', 'g') ilike '%12mm%' then
                  v_glass_has_12mm := true;
                elsif regexp_replace(coalesce(v_line_name, '') || ' ' || coalesce(v_line_note, '') || ' ' || coalesce(v_product_display_id, ''), '\s+', '', 'g') ilike '%10mm%' then
                  v_glass_has_10mm := true;
                end if;

                insert into public."OnlineOrderLines" (
                  "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "GrossAmount", "Note", "Description", "SyncedAtUtc"
                ) values (
                  v_order_id, v_line_id, v_product_display_id, v_product_display_id, nullif(v_variation_id, ''), v_qty, null, v_price, v_price * v_qty, nullif(v_line_note, ''), nullif(v_line_name, ''), now()
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

                v_lines_synced := v_lines_synced + 1;
              exception when others then
                null; -- skip malformed line, keep processing the rest
              end;
            end loop;

            v_glass_thickness := case when v_glass_has_12mm then '12mm' when v_glass_has_10mm then '10mm' else null end;
            v_note_print := nullif(trim(coalesce(v_order_el ->> 'note_print', v_order_el ->> 'notePrint', '')), '');

            update public."OnlineOrders"
              set "GlassThickness" = v_glass_thickness, "GlassThicknessCheckedAt" = now(),
                  "NotePrint" = coalesce(v_note_print, "NotePrint"), "NotePrintCheckedAt" = now()
              where "OrderID" = v_order_id;
          end if;
        exception when others then
          null; -- order detail fetch failed/timed out - header is still synced, lines will retry next click
        end;

      exception when others then
        null; -- skip malformed order, keep processing the rest
      end;
    end loop;

    exit when v_items_this_page < v_page_size;
  end loop;

  insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
  values ('/orders', v_max_run_utc)
  on conflict ("Entity") do update set "LastSyncUtc" = excluded."LastSyncUtc";

  return query select v_orders_synced, v_orders_inserted, v_orders_updated, v_lines_synced;
end;
$$;

grant execute on function public.admin_sync_online_orders_from_pancake(text, text, int, int) to anon;

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
        end loop;

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
create or replace function public.admin_list_online_orders_live(
  p_admin_username text,
  p_admin_password text,
  p_search text default null,
  p_status text default null,
  p_page int default 1,
  p_page_size int default 100,
  p_walk_started_at timestamptz default null
)
returns table(
  order_id text,
  order_date date,
  order_time text,
  status text,
  customer_name text,
  location_id text,
  warehouse_name text,
  money_to_collect numeric,
  amount_paid numeric,
  discount numeric,
  balance numeric,
  for_delivery boolean,
  shipping_address text,
  estimated_delivery_date date,
  last_updated_at timestamptz,
  has_more boolean,
  debug_url text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_page_size int := least(greatest(coalesce(p_page_size, 100), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_url text;
  v_last_sync_utc timestamptz;
  v_apply_since_filter boolean;
  v_since_qs text := '';
  v_iso text;
  v_response extensions.http_response;
  v_body jsonb;
  v_items jsonb;
  v_item jsonb;
  v_items_this_page int;
  v_has_more boolean;
  v_row_count int := 0;
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
  v_last_updated_raw text;
  v_last_updated_utc timestamptz;
  v_for_delivery_kind text;
  v_for_delivery boolean;
  v_shipping_address text;
  v_shipping_phone text;
  v_est_delivery_raw text;
  v_est_delivery_date date;
  v_matches_filters boolean;
  v_warehouse_name text;
  v_created_by text;
  v_confirmed_by text;
  v_confirmed_at timestamptz;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  -- Only ever ONE Pancake call per invocation now, so a generous-but-bounded
  -- per-call timeout is fine - it can't accumulate into an external cancel.
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  -- Only skip straight to "what changed since last time" when browsing with no active
  -- search/status filter - see the header comment above for why search always walks
  -- the full catalog instead.
  v_apply_since_filter := (p_search is null or trim(p_search) = '') and (p_status is null or trim(p_status) = '');

  if v_apply_since_filter then
    select "LastSyncUtc" into v_last_sync_utc from public."PancakeSyncState" where "Entity" = '/orders';
    if v_last_sync_utc is not null then
      v_iso := to_char(v_last_sync_utc at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
      v_since_qs := '&updated_after=' || v_iso || '&updatedAfter=' || v_iso
        || '&created_after=' || v_iso || '&createdAfter=' || v_iso || '&since=' || v_iso;
    end if;
  end if;

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
  -- A full raw page (before our own filters below) means there's likely a next page to fetch.
  v_has_more := (v_items_this_page = v_page_size);

  -- Once a since-filtered walk reaches its last page, advance the shared cursor so the NEXT
  -- plain browse only asks for what changed after this walk started. Guarded so a slower,
  -- overlapping call can never move the cursor backwards. Skipped entirely for search/status-
  -- filtered walks (v_apply_since_filter false) and for callers that didn't pass a start time.
  if not v_has_more and v_apply_since_filter and p_walk_started_at is not null then
    insert into public."PancakeSyncState" ("Entity", "LastSyncUtc")
    values ('/orders', p_walk_started_at)
    on conflict ("Entity") do update
      set "LastSyncUtc" = excluded."LastSyncUtc"
      where public."PancakeSyncState"."LastSyncUtc" is null
         or excluded."LastSyncUtc" > public."PancakeSyncState"."LastSyncUtc";
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

      -- NOTE: filter mismatches no longer `continue` here - every valid order on this page still
      -- gets its fields computed and persisted below (see v_matches_filters), so browsing with a
      -- search/status filter active doesn't silently skip persisting the orders being filtered out.
      v_matches_filters := not (p_status is not null and trim(p_status) <> '' and v_status not ilike '%' || p_status || '%');

      v_customer := coalesce(
        v_item -> 'customer' ->> 'name', v_item -> 'customer' ->> 'customer_name', v_item -> 'customer' ->> 'full_name',
        v_item ->> 'customer_name', v_item ->> 'customer', v_item ->> 'client_name', v_item ->> 'buyer_name'
      );

      if v_matches_filters and p_search is not null and trim(p_search) <> ''
         and v_order_id not ilike '%' || p_search || '%'
         and coalesce(v_customer, '') not ilike '%' || p_search || '%' then
        v_matches_filters := false;
      end if;

      v_created_raw := coalesce(v_item ->> 'inserted_at', v_item ->> 'insertedAt', v_item ->> 'created_at', v_item ->> 'createdAt', v_item ->> 'date', v_item ->> 'created');
      v_created_utc := public.pancake_try_parse_timestamptz(v_created_raw);
      if v_created_utc is not null then
        v_date := (v_created_utc at time zone 'Asia/Manila')::date;
        v_time := to_char(v_created_utc at time zone 'Asia/Manila', 'HH24:MI:SS');
      else
        v_date := null;
        v_time := null;
      end if;

      v_location_id := coalesce(v_item ->> 'warehouse_id', v_item ->> 'warehouseId');

      -- Resolve the human-readable warehouse name (public."Warehouses" is kept in sync by
      -- admin_sync_warehouses_from_pancake / the desktop app's own warehouse sync) - falls back
      -- to null (client displays the raw location_id instead) if no match is found.
      select "Name" into v_warehouse_name from public."Warehouses" where "ID" = v_location_id;

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

      v_last_updated_raw := coalesce(v_item ->> 'updated_at', v_item ->> 'updatedAt', v_item ->> 'last_updated_at', v_item ->> 'lastUpdatedAt');
      v_last_updated_utc := public.pancake_try_parse_timestamptz(v_last_updated_raw);

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

      -- AUTOMATIC PERSISTENCE: upsert this order's header into the local mirror table as it's
      -- fetched for live display, regardless of whether it matches the caller's search/status
      -- filter - this is what keeps public."OnlineOrders" (and therefore the status summary
      -- counts and the non-live admin_list_online_orders) populated automatically just from
      -- staff browsing the Online Orders page, without needing the desktop app's push sync or
      -- the manual "Sync from Pancake" button to have run first. Order LINES are deliberately
      -- NOT synced here - that needs one extra Pancake HTTP call per order, which would turn
      -- this single-page-per-call function back into the slow N+1 pattern it was rewritten to
      -- avoid (see the comment above this function). Lines are instead fetched live, on demand,
      -- by admin_get_online_order_detail_live when a specific order is opened, or filled in by
      -- the desktop app / the manual sync button. Best-effort: a persistence failure must never
      -- prevent the row from still being shown to the caller.
      --
      -- SKIP-IF-UNCHANGED: the `where` clause on the conflict update means Postgres only
      -- actually rewrites the row when Pancake's own "Last_Updated_At" (or Status, as a
      -- fallback for orders Pancake doesn't return an updated_at for) differs from what's
      -- already stored - since every staff page-load re-fetches and re-upserts the same
      -- orders, this avoids needless writes for orders that haven't changed since they were
      -- last persisted. No extra table/read needed - "Last_Updated_At"/"SyncedAtUtc" already
      -- live on this same row and are what track "when did this order last change" (Pancake's
      -- timestamp) vs. "when did we last touch this row" (ours) respectively.
      select t.created_by, t.confirmed_by, t.confirmed_at into v_created_by, v_confirmed_by, v_confirmed_at
      from public.pancake_extract_created_confirmed_by(v_item) t;

      begin
        insert into public."OnlineOrders" (
          "OrderID", "Date", "Time", "Status", "CustomerName", "LocationID",
          "MoneyToCollect", "AmountPaid", "Discount", "DeliveryFee", "Balance", "ForDelivery", "ShippingAddress", "ShippingPhone",
          "EstimatedDeliveryDate", "Last_Updated_At", "ReceivedAtShop", "CreatedBy", "ConfirmedBy", "ConfirmedAtUtc", "SyncedAtUtc"
        ) values (
          v_order_id, v_date, v_time, v_status, v_customer, v_location_id,
          v_money_to_collect, v_amount_paid, v_discount, v_delivery_fee, v_balance, v_for_delivery, v_shipping_address, v_shipping_phone,
          v_est_delivery_date, v_last_updated_utc, v_received_at_shop, v_created_by, v_confirmed_by, v_confirmed_at, now()
        )
        on conflict ("OrderID") do update set
          "Date" = excluded."Date",
          "Time" = excluded."Time",
          "Status" = excluded."Status",
          "CustomerName" = excluded."CustomerName",
          "LocationID" = excluded."LocationID",
          "MoneyToCollect" = excluded."MoneyToCollect",
          "AmountPaid" = excluded."AmountPaid",
          "Discount" = excluded."Discount",
          "DeliveryFee" = excluded."DeliveryFee",
          "ShippingPhone" = excluded."ShippingPhone",
          "Balance" = excluded."Balance",
          "ForDelivery" = excluded."ForDelivery",
          "ShippingAddress" = excluded."ShippingAddress",
          "EstimatedDeliveryDate" = excluded."EstimatedDeliveryDate",
          "Last_Updated_At" = excluded."Last_Updated_At",
          "ReceivedAtShop" = excluded."ReceivedAtShop",
          "CreatedBy" = coalesce(excluded."CreatedBy", "OnlineOrders"."CreatedBy"),
          "ConfirmedBy" = coalesce(excluded."ConfirmedBy", "OnlineOrders"."ConfirmedBy"),
          "ConfirmedAtUtc" = coalesce(excluded."ConfirmedAtUtc", "OnlineOrders"."ConfirmedAtUtc"),
          "SyncedAtUtc" = now()
        where public."OnlineOrders"."Last_Updated_At" is distinct from excluded."Last_Updated_At"
           or public."OnlineOrders"."Status" is distinct from excluded."Status"
           or public."OnlineOrders"."ReceivedAtShop" is distinct from excluded."ReceivedAtShop"
           or (excluded."ConfirmedBy" is not null and public."OnlineOrders"."ConfirmedBy" is distinct from excluded."ConfirmedBy")
           or (excluded."CreatedBy" is not null and public."OnlineOrders"."CreatedBy" is distinct from excluded."CreatedBy");
      exception when others then
        null; -- persistence is best-effort - never let it block showing the live row
      end;

      -- Walk-in/in-store orders (ReceivedAtShop = true) are persisted above so dashboard
      -- reporting (Walk-In Sales) picks them up, but are never returned to this live-browse
      -- caller - the Online Orders page is specifically for online/delivery orders, matching
      -- its behavior before walk-in orders were captured at all.
      if v_received_at_shop or not v_matches_filters then
        continue;
      end if;

      v_row_count := v_row_count + 1;
      order_id := v_order_id;
      order_date := v_date;
      order_time := v_time;
      status := v_status;
      customer_name := v_customer;
      location_id := v_location_id;
      warehouse_name := v_warehouse_name;
      money_to_collect := v_money_to_collect;
      amount_paid := v_amount_paid;
      discount := v_discount;
      balance := v_balance;
      for_delivery := v_for_delivery;
      shipping_address := v_shipping_address;
      estimated_delivery_date := v_est_delivery_date;
      last_updated_at := v_last_updated_utc;
      has_more := v_has_more;
      debug_url := v_url;
      return next;
    exception when others then
      null; -- skip malformed order row, keep processing the rest
    end;
  end loop;

  -- If every item on this page got filtered out (e.g. all "new"/search mismatch), still emit
  -- one sentinel row so the client learns has_more without seeing a false "no orders" result.
  -- The client treats order_id IS NULL as "not a real order, just a has_more signal" and skips it.
  if v_row_count = 0 then
    order_id := null;
    order_date := null;
    order_time := null;
    status := null;
    customer_name := null;
    location_id := null;
    warehouse_name := null;
    money_to_collect := null;
    amount_paid := null;
    discount := null;
    balance := null;
    for_delivery := null;
    shipping_address := null;
    estimated_delivery_date := null;
    last_updated_at := null;
    has_more := v_has_more;
    debug_url := v_url;
    return next;
  end if;
end;
$$;

grant execute on function public.admin_list_online_orders_live(text, text, text, text, int, int, timestamptz) to anon;

-- Backfill: recompute Balance for every order already sitting in OnlineOrders, using the same
-- fields (MoneyToCollect/AmountPaid) that are already correctly stored - no re-fetch from Pancake
-- needed. Fixes existing wrong balances immediately rather than waiting for the next sync touch.
update public."OnlineOrders"
set "Balance" = coalesce("MoneyToCollect", 0) - coalesce("AmountPaid", 0)
where "Balance" is distinct from (coalesce("MoneyToCollect", 0) - coalesce("AmountPaid", 0));

notify pgrst, 'reload schema';
