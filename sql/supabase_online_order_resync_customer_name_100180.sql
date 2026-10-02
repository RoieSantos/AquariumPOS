-- Resync order 100180's customer name from Pancake - per "i notice one its not updated on order 100180".
--
-- WHY IT MISSED: the shipping_address.full_name fix (supabase_online_order_balance_local_calc.sql /
-- _sync_edited_lines / _fill_stub_rows) only reaches an order when a sync re-reads it. The every-minute
-- header sync only reads orders Pancake reports as updated after its cursor, and the open-order refresh
-- only picks Confirmed/Printed/Assigned/To Ship/In-Transit/Pending Transfer - so an older order that
-- hasn't changed in Pancake since keeps its old (FB profile) name.
--
-- 1. Forces a full header resync of 100180 (_refresh_open_online_order with p_force_header) - same name
--    mapping as the syncs: shipping_address.full_name -> bill_full_name -> FB profile name.
-- 2. Result grid: the portal's CustomerName next to what Pancake has in each name field, so if it's
--    still not right you can see whether Pancake's recipient name is blank/different.
--
-- Needs supabase_online_order_fill_stub_rows.sql run first. Safe to re-run; edit the order id in all
-- three places to use it for another order.

do $$
begin
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '20000');
  perform public._refresh_open_online_order('100180', true);
end;
$$;

with pancake as (
  select coalesce(case when jsonb_typeof(b -> 'data') = 'object' then b -> 'data' end, b) as el
  from (
    select (extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders/100180?api_key='
      || public._pancake_api_key())).content::jsonb as b
  ) r
)
select o."OrderID",
       o."Status",
       o."CustomerName" as portal_customer_name,
       p.el -> 'shipping_address' ->> 'full_name' as pancake_shipping_full_name,
       p.el ->> 'bill_full_name' as pancake_bill_full_name,
       p.el -> 'customer' ->> 'name' as pancake_fb_profile_name,
       p.el ->> 'status_name' as pancake_status,
       o."SyncedAtUtc" at time zone 'Asia/Manila' as synced_manila
from public."OnlineOrders" o
cross join pancake p
where o."OrderID" = '100180';
