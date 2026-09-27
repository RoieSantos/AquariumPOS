-- Read-only diagnostic: why can't Online Order 100768 (POS walk-in, Shipped) be found in the
-- Delivery calendar's "Assign Order to Delivery" search (admin_list_deliverable_online_orders)?
--
-- That picker only lists public."OnlineOrders" rows where ForDelivery is not true AND Status is
-- Confirmed/Printed/To Ship/Shipped. Note ForDelivery is overwritten on every Pancake sync from
-- Pancake's own is_free_shipping flag - so a "free shipping" tick in Pancake hides the order here.
-- Run each block separately in the Supabase SQL editor.

-- 1) Is it in the portal at all, and which filter excludes it?
select o."OrderID", o."Status", o."ForDelivery", o."ReceivedAtShop", o."CustomerName",
       o."ShippingAddress", o."Last_Updated_At", o."SyncedAtUtc",
       case
         when o."ForDelivery" is true then 'HIDDEN: ForDelivery = true (already assigned, or Pancake "free shipping" is ticked)'
         when lower(o."Status") not in ('confirmed', 'printed', 'to ship', 'shipped') then 'HIDDEN: status "' || coalesce(o."Status", 'null') || '" not in the deliverable list'
         else 'SHOULD SHOW - check search text'
       end as verdict
from public."OnlineOrders" o
where o."OrderID" ilike '%100768%';
-- No rows = the order never synced from Pancake -> see block 3.

-- 2) Does it already have a delivery stop (i.e. it's already on the calendar)?
select s."StopID", s."OrderID", s."DeliveryDate"
from public."DeliveryStops" s
where s."OrderID" ilike '%100768%';

-- 3) What does Pancake itself say about the order right now?
select r.status as http_status,
       r.content::jsonb -> 'data' ->> 'status'           as pancake_status,
       r.content::jsonb -> 'data' ->> 'status_name'      as pancake_status_name,
       r.content::jsonb -> 'data' ->> 'received_at_shop' as received_at_shop,
       r.content::jsonb -> 'data' ->> 'is_free_shipping' as is_free_shipping,
       r.content::jsonb -> 'data' ->> 'updated_at'       as updated_at,
       (select "LastSyncUtc" from public."PancakeSyncState" where "Entity" = '/orders') as sync_cursor
from extensions.http_get(
  'https://pos.pages.fm/api/v1/shops/1328301944/orders/100768?api_key=' || public._pancake_api_key()
) r;
