-- Resync specific orders from Pancake into Online Orders on demand - per "can we just resync over this
-- 103279 and 100180 order from pancake going to portal".
--
-- For each order: re-fills the full header from Pancake (status, customer, phone, address, totals, dates,
-- warehouse - _refresh_open_online_order with p_force_header), then re-saves its item lines / glass
-- thickness / print note (_sync_online_order_detail). An order missing from Online Orders entirely is
-- added first as an empty row, then filled the same way.
--
-- Needs supabase_online_order_fill_stub_rows.sql run first (adds p_force_header). Edit the order list in
-- both places below, run the whole file, and check the result grid at the end.

-- ---------------------------------------------------------------------------
-- 1. Add any of the orders that aren't on Online Orders at all yet (as an empty row the refresh fills).
insert into public."OnlineOrders" ("OrderID")
select o.order_id
from unnest(array['103279', '100180']) as o(order_id)
where not exists (select 1 from public."OnlineOrders" x where x."OrderID" = o.order_id);

-- ---------------------------------------------------------------------------
-- 2. Resync header + lines from Pancake.
do $$
declare
  v_order_id text;
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  foreach v_order_id in array array['103279', '100180'] loop
    perform public._refresh_open_online_order(v_order_id, true);
    perform public._sync_online_order_detail(v_order_id);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Result. SyncedAtUtc should be "just now". If an order still has a blank Status/Customer, Pancake
--    didn't return it: either the id isn't a Pancake order id, or the order is still 'new' in Pancake
--    (not confirmed yet - the sync skips those on purpose).
select o."OrderID", o."Status", o."CustomerName", o."Date", o."LocationID", o."MoneyToCollect", o."Balance",
       o."SyncedAtUtc" at time zone 'Asia/Manila' as synced_manila,
       (select count(*) from public."OnlineOrderLines" l where l."OrderID" = o."OrderID") as line_count
from public."OnlineOrders" o
where o."OrderID" in ('103279', '100180');
