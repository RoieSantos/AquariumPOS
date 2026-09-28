-- Keep open orders' lines in step with Pancake - per "still not allowing to assign to stand maker even
-- though i have a Custom-Stand on the lines" (order 103949: the CUSTOM-STAND added in Pancake at
-- 4:56 PM never reached OnlineOrderLines).
--
-- The every-minute cron_sync_online_orders_from_pancake only re-reads an edited order's lines when its
-- check timestamps say so (see supabase_online_order_sync_edited_lines.sql), which a single overlapping
-- run can still defeat. cron_refresh_open_online_order_statuses (supabase_online_order_open_status_
-- refresh.sql) already fetches the full detail of every open order in rotation (40 a minute, least
-- recently synced first) - it now also saves those lines: adds/updates each line, and removes lines
-- deleted in Pancake (only when Pancake returned at least one line, so a bad response never wipes an
-- order). No extra Pancake calls, and no dependency on timestamps.
--
-- Also adds 'Assigned' to the open statuses it refreshes (it predates that status).
-- Run AFTER supabase_online_order_open_status_refresh.sql. Replaces the function only; the existing
-- every-minute cron job calls it by name, so no reschedule is needed.

create or replace function public.cron_refresh_open_online_order_statuses(
  p_max_orders int default 40
)
returns table(orders_checked int, orders_changed int)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shop_id text := '1328301944';
  v_api_key text := public._pancake_api_key();
  v_base_url text := 'https://pos.pages.fm/api/v1';
  v_max int := least(greatest(coalesce(p_max_orders, 40), 1), 200);
  v_order_id text;
  v_old_status text;
  v_response extensions.http_response;
  v_body jsonb;
  v_el jsonb;
  v_status_raw text;
  v_status text;
  v_updated_raw text;
  v_updated_utc timestamptz;
  v_checked int := 0;
  v_changed int := 0;
  v_line_item jsonb;
  v_variation_info jsonb;
  v_product_display_id text;
  v_variation_id text;
  v_qty numeric;
  v_price numeric;
  v_line_name text;
  v_line_note text;
  v_line_id text;
  v_seen text[];
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');

  for v_order_id, v_old_status in
    select "OrderID", "Status" from public."OnlineOrders"
    where "Status" in ('Confirmed', 'Printed', 'Assigned', 'To Ship', 'In-Transit', 'Pending Transfer')
      and coalesce("ReceivedAtShop", false) is not true
    order by "SyncedAtUtc" asc nulls first
    limit v_max
  loop
    begin
      v_response := extensions.http_get(
        v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order_id || '?api_key=' || v_api_key || '&page_size=1000'
      );
      if v_response.status < 200 or v_response.status >= 300 then
        continue; -- retried on a future run
      end if;

      v_body := v_response.content::jsonb;
      v_el := case
        when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
        when jsonb_typeof(v_body) = 'object' then v_body
        else null
      end;
      if v_el is null then
        continue;
      end if;

      v_status_raw := coalesce(v_el ->> 'status_name', v_el ->> 'status', v_el ->> 'state', v_el ->> 'order_status');
      if v_status_raw is null or lower(trim(v_status_raw)) in ('', 'new') then
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

      v_checked := v_checked + 1;

      v_updated_raw := coalesce(v_el ->> 'updated_at', v_el ->> 'last_updated_at');
      begin
        v_updated_utc := v_updated_raw::timestamptz;
      exception when others then
        v_updated_utc := null;
      end;

      update public."OnlineOrders"
        set "Status" = v_status,
            "Last_Updated_At" = coalesce(v_updated_utc, "Last_Updated_At"),
            "SyncedAtUtc" = now()
        where "OrderID" = v_order_id;

      if v_status is distinct from v_old_status then
        v_changed := v_changed + 1;
      end if;

      -- Lines: same mapping as the cron sync's lines pass (supabase_pancake_manual_sync.sql).
      if jsonb_typeof(v_el -> 'items') = 'array' then
        v_seen := array[]::text[];
        for v_line_item in select * from jsonb_array_elements(v_el -> 'items')
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

            v_seen := array_append(v_seen, v_line_id);
          exception when others then
            null; -- skip malformed line, keep processing the rest
          end;
        end loop;

        if cardinality(v_seen) > 0 then
          delete from public."OnlineOrderLines" l
          where l."OrderID" = v_order_id and not (l."LineID" = any(v_seen));
        end if;
      end if;
    exception when others then
      null; -- skip this order, retried on a future run
    end;
  end loop;

  return query select v_checked, v_changed;
end;
$$;

revoke all on function public.cron_refresh_open_online_order_statuses(int) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Order 103949 right now: put it first in the refresh rotation, so its lines are saved within a
--    minute. Then check with sql/supabase_check_online_order_maker_lines.sql.
update public."OnlineOrders" set "SyncedAtUtc" = null where "OrderID" = '103949';
