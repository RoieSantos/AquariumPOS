-- Stop the background Pancake syncs from holding orders locked for a minute at a time - per "error on
-- assigning order": "Tank Maker: canceling statement due to statement timeout · Stand Maker: ...".
--
-- CAUSE: saving a maker is a one-row update, but it had to wait for a row lock. Two every-minute jobs
-- update an order and then keep making Pancake calls for OTHER orders in the same transaction, so
-- every order they touched stayed locked until the whole run finished (tens of seconds):
--   - sync-online-orders-from-pancake: upserts changed order headers, then runs the glass + lines
--     passes (up to 60 Pancake detail calls) in the same transaction.
--   - refresh-open-online-order-statuses: updates each open order, then fetches the next (40 calls).
-- A new or just-edited order is touched by both, so assigning it right away usually timed out.
--
-- FIX: per-order work now commits after each order, so an order is locked only for its own quick write.
--   1. The header sync runs headers only (glass/lines passes switched off via its arguments).
--   2. New procedure cron_sync_online_order_details: the glass + lines + print-note work, one order at a
--      time, COMMIT after each. Same candidates as before (orders with no lines, never checked, or
--      edited in Pancake since last checked), up to 60 a run. Also removes lines deleted in Pancake.
--   3. New procedure cron_refresh_open_online_orders: the open-order status + lines refresh, one order
--      at a time, COMMIT after each (same work as cron_refresh_open_online_order_statuses).
-- Pancake calls run outside any held lock except the order's own brief update.
--
-- Run AFTER supabase_online_order_open_refresh_lines.sql. Reschedules the two jobs. No table locks.

-- ---------------------------------------------------------------------------
-- Saves one order's detail from Pancake: lines (add/update, remove deleted), glass thickness, print
-- note, both check timestamps. Raises on a failed fetch (caller skips the order).
create or replace function public._sync_online_order_detail(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_response extensions.http_response;
  v_body jsonb;
  v_el jsonb;
  v_item jsonb;
  v_info jsonb;
  v_pdid text;
  v_variation_id text;
  v_qty numeric;
  v_price numeric;
  v_name text;
  v_note text;
  v_line_id text;
  v_seen text[] := array[]::text[];
  v_has_12 boolean := false;
  v_has_10 boolean := false;
  v_note_print text;
begin
  v_response := extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id
    || '?api_key=' || public._pancake_api_key() || '&page_size=1000');
  if v_response.status < 200 or v_response.status >= 300 then
    raise exception 'Pancake detail HTTP %', v_response.status;
  end if;

  v_body := v_response.content::jsonb;
  v_el := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' then v_body
    else null
  end;
  if v_el is null then
    raise exception 'Pancake returned no order';
  end if;

  if jsonb_typeof(v_el -> 'items') = 'array' then
    for v_item in select * from jsonb_array_elements(v_el -> 'items')
    loop
      begin
        v_info := v_item -> 'variation_info';
        v_pdid := coalesce(v_info ->> 'product_display_id', v_item ->> 'product_display_id');
        v_name := coalesce(v_info ->> 'name', v_item ->> 'name');
        v_note := v_item ->> 'note';

        if regexp_replace(coalesce(v_name, '') || ' ' || coalesce(v_note, '') || ' ' || coalesce(v_pdid, ''), '[[:space:]]+', '', 'g') ilike '%12mm%' then
          v_has_12 := true;
        elsif regexp_replace(coalesce(v_name, '') || ' ' || coalesce(v_note, '') || ' ' || coalesce(v_pdid, ''), '[[:space:]]+', '', 'g') ilike '%10mm%' then
          v_has_10 := true;
        end if;

        if v_pdid is null or trim(v_pdid) = '' then
          continue;
        end if;

        v_variation_id := coalesce(v_info ->> 'variation_id', v_item ->> 'variation_id', v_item ->> 'variationId');
        v_qty := public.pancake_parse_decimal(v_item ->> 'quantity');
        v_price := public.pancake_parse_decimal(coalesce(v_info ->> 'retail_price', v_item ->> 'retail_price'));
        v_line_id := coalesce(
          v_item ->> 'line_id', v_item ->> 'id', v_item ->> 'order_line_id',
          v_item ->> 'order_item_id', v_item ->> 'item_id', ''
        );

        insert into public."OnlineOrderLines" (
          "OrderID", "LineID", "ItemCode", "product_display_id", "VariationId", "Quantity", "UnitCost", "Price", "GrossAmount", "Note", "Description", "SyncedAtUtc"
        ) values (
          p_order_id, v_line_id, v_pdid, v_pdid, nullif(v_variation_id, ''), v_qty, null, v_price, v_price * v_qty, nullif(v_note, ''), nullif(v_name, ''), now()
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

    -- Only when Pancake returned at least one line, so a bad response never wipes an order.
    if cardinality(v_seen) > 0 then
      delete from public."OnlineOrderLines" l
      where l."OrderID" = p_order_id and not (l."LineID" = any(v_seen));
    end if;
  end if;

  v_note_print := nullif(trim(coalesce(v_el ->> 'note_print', v_el ->> 'notePrint', '')), '');
  update public."OnlineOrders"
    set "GlassThickness" = case when v_has_12 then '12mm' when v_has_10 then '10mm' else null end,
        "GlassThicknessCheckedAt" = now(),
        "NotePrint" = coalesce(v_note_print, "NotePrint"),
        "NotePrintCheckedAt" = now()
    where "OrderID" = p_order_id;
end;
$$;

revoke execute on function public._sync_online_order_detail(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- No SECURITY DEFINER / SET clause here: Postgres forbids COMMIT in a procedure that has either. It's
-- only run by pg_cron (as the owner), and every name inside is schema-qualified.
create or replace procedure public.cron_sync_online_order_details(p_max_orders int default 60)
language plpgsql
as $$
declare
  v_order_id text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');

  for v_order_id in
    select o."OrderID" from public."OnlineOrders" o
    where not exists (select 1 from public."OnlineOrderLines" l where l."OrderID" = o."OrderID")
       or o."GlassThicknessCheckedAt" is null
       or o."NotePrintCheckedAt" is null
       or (o."Last_Updated_At" is not null
           and (o."Last_Updated_At" > o."GlassThicknessCheckedAt" or o."Last_Updated_At" > o."NotePrintCheckedAt"))
    order by o."Last_Updated_At" desc nulls last
    limit least(greatest(coalesce(p_max_orders, 60), 1), 200)
  loop
    begin
      perform public._sync_online_order_detail(v_order_id);
    exception when others then
      null; -- retried on a future run
    end;
    commit; -- release this order's lock right away
  end loop;
end;
$$;

revoke execute on procedure public.cron_sync_online_order_details(int) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- One open order: status (and Last_Updated_At) from Pancake, plus its lines/glass/print note.
-- supabase_online_order_fill_stub_rows.sql replaces this with a (text, boolean) version - drop that first so
-- re-running this file never leaves both (the cron's one-argument call would be ambiguous). Re-run
-- fill_stub_rows.sql after this file.
drop function if exists public._refresh_open_online_order(text, boolean);

create or replace function public._refresh_open_online_order(p_order_id text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_response extensions.http_response;
  v_body jsonb;
  v_el jsonb;
  v_status_raw text;
  v_status text;
  v_updated_utc timestamptz;
begin
  v_response := extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders/' || p_order_id
    || '?api_key=' || public._pancake_api_key());
  if v_response.status < 200 or v_response.status >= 300 then
    return;
  end if;

  v_body := v_response.content::jsonb;
  v_el := case
    when jsonb_typeof(v_body -> 'data') = 'object' then v_body -> 'data'
    when jsonb_typeof(v_body) = 'object' then v_body
    else null
  end;
  if v_el is null then
    return;
  end if;

  v_status_raw := coalesce(v_el ->> 'status_name', v_el ->> 'status', v_el ->> 'state', v_el ->> 'order_status');
  if v_status_raw is null or lower(trim(v_status_raw)) in ('', 'new') then
    return;
  end if;

  -- Same mapping as cron_refresh_open_online_order_statuses (Assigned/"waitting" is normalized by the
  -- OnlineOrders status trigger).
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

  begin
    v_updated_utc := coalesce(v_el ->> 'updated_at', v_el ->> 'last_updated_at')::timestamptz;
  exception when others then
    v_updated_utc := null;
  end;

  update public."OnlineOrders"
    set "Status" = v_status,
        "Last_Updated_At" = coalesce(v_updated_utc, "Last_Updated_At"),
        "SyncedAtUtc" = now()
    where "OrderID" = p_order_id;
end;
$$;

revoke execute on function public._refresh_open_online_order(text) from public, anon, authenticated;

create or replace procedure public.cron_refresh_open_online_orders(p_max_orders int default 40)
language plpgsql
as $$
declare
  v_order_id text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');

  for v_order_id in
    select "OrderID" from public."OnlineOrders"
    where "Status" in ('Confirmed', 'Printed', 'Assigned', 'To Ship', 'In-Transit', 'Pending Transfer')
      and coalesce("ReceivedAtShop", false) is not true
    order by "SyncedAtUtc" asc nulls first
    limit least(greatest(coalesce(p_max_orders, 40), 1), 200)
  loop
    begin
      perform public._refresh_open_online_order(v_order_id);
    exception when others then
      null; -- retried on a future run
    end;
    commit;
  end loop;
end;
$$;

revoke execute on procedure public.cron_refresh_open_online_orders(int) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Reschedule. The header sync keeps its name/schedule but skips the glass/lines passes (last two
-- arguments 0) - cron_sync_online_order_details does that work now. Lines of open orders are kept
-- current by the details job whenever Pancake's edit time moves; the open refresh keeps statuses.
do $$
begin
  perform cron.unschedule('sync-online-orders-from-pancake');
exception when others then null;
end;
$$;
select cron.schedule('sync-online-orders-from-pancake', '* * * * *',
  $$select public.cron_sync_online_orders_from_pancake(100, 100, 0, 0);$$);

do $$
begin
  perform cron.unschedule('sync-online-order-details');
exception when others then null;
end;
$$;
select cron.schedule('sync-online-order-details', '* * * * *',
  $$call public.cron_sync_online_order_details();$$);

do $$
begin
  perform cron.unschedule('refresh-open-online-order-statuses');
exception when others then null;
end;
$$;
select cron.schedule('refresh-open-online-order-statuses', '* * * * *',
  $$call public.cron_refresh_open_online_orders();$$);
