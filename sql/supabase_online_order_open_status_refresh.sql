-- ---------------------------------------------------------------------------
-- Open-status refresh for OnlineOrders.
--
-- Problem: the every-minute order sync (cron_sync_online_orders_from_pancake) only asks Pancake for
-- orders "updated after" a cursor. If Pancake doesn't bump last_updated_at (or ignores the filter)
-- when an order moves on to Delivered, the portal row stays at Printed/Confirmed/To Ship forever.
--
-- Fix: independent of the cursor, re-fetch each still-open order's DETAIL from Pancake and
-- overwrite its Status. Least-recently-touched first ("SyncedAtUtc" is bumped on every refresh, so
-- the batch rotates through all open orders). Once an order reaches Shipped/Received/etc. it drops
-- out of the open set on its own.
--
-- Separate function + separate cron job so the existing big sync function isn't touched.
-- Status mapping mirrors cron_sync_online_orders_from_pancake / admin_list_online_orders_live.
-- ---------------------------------------------------------------------------

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
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');

  for v_order_id, v_old_status in
    select "OrderID", "Status" from public."OnlineOrders"
    where "Status" in ('Confirmed', 'Printed', 'To Ship', 'In-Transit', 'Pending Transfer')
      and coalesce("ReceivedAtShop", false) is not true
    order by "SyncedAtUtc" asc nulls first
    limit v_max
  loop
    begin
      v_response := extensions.http_get(
        v_base_url || '/shops/' || v_shop_id || '/orders/' || v_order_id || '?api_key=' || v_api_key
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
    exception when others then
      null; -- skip this order, retried on a future run
    end;
  end loop;

  return query select v_checked, v_changed;
end;
$$;

revoke all on function public.cron_refresh_open_online_order_statuses(int) from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('refresh-open-online-order-statuses');
exception when others then
  null; -- job didn't exist yet
end;
$$;

select cron.schedule(
  'refresh-open-online-order-statuses',
  '* * * * *',
  $$select public.cron_refresh_open_online_order_statuses();$$
);
