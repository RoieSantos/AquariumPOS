-- Read-only: why the Dashboard's Walk-In "By branch · tender" shows GMA Cash 5,627 + GCASH 5,932 (11,559)
-- under a GMA total of only 5,121 (8 orders). One row per GMA walk-in order today: the portal's
-- MoneyToCollect / AmountPaid next to the stored OnlineOrderPayments rows, plus the payment fields
-- Pancake returns for that order right now (one live GET per order).
--
-- What to look for:
--   paid_rows_sum > money_to_collect   -> stored payments too big for that order
--   pancake_total differs from portal  -> the stored row belongs to a different Pancake order (ID clash)
--   pancake cash much bigger than total -> Pancake's "cash" is cash tendered (before change)

with orders as (
  select o."OrderID" as order_id, o."MoneyToCollect" as total, o."AmountPaid" as amount_paid, o."Status" as status
  from public."OnlineOrders" o
  join public."Warehouses" w on w."ID" = o."LocationID"
  where w."Name" ilike '%GMA%'
    and o."ReceivedAtShop" is true
    and o."Date" = (now() at time zone 'Asia/Manila')::date
    and lower(trim(coalesce(o."Status", ''))) not in ('canceled', 'cancelled')
),
stored as (
  select p."OrderID" as order_id,
         sum(p."Amount") as paid_sum,
         string_agg(public._payment_method_label(p."MethodCode") || ' ' || p."Amount", ', ' order by p."MethodCode") as paid_rows
  from public."OnlineOrderPayments" p
  where p."OrderID" in (select order_id from orders)
  group by p."OrderID"
),
live as (
  select x.order_id,
         (select case when jsonb_typeof(r.content::jsonb -> 'data') = 'object' then r.content::jsonb -> 'data'
                      else r.content::jsonb end
            from extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders/' || x.order_id
                                     || '?api_key=' || public._pancake_api_key()) r) as o
  from orders x
)
select x.order_id,
       x.status,
       x.total as money_to_collect,
       x.amount_paid,
       s.paid_sum as paid_rows_sum,
       s.paid_rows,
       l.o ->> 'id' as pancake_id,
       l.o ->> 'receipt_no' as pancake_receipt_no,
       coalesce(l.o ->> 'total_price', l.o ->> 'total') as pancake_total,
       l.o ->> 'money_to_collect' as pancake_money_to_collect,
       l.o ->> 'prepaid' as pancake_prepaid,
       l.o ->> 'cash' as pancake_cash,
       l.o ->> 'change' as pancake_change,
       (l.o -> 'bank_payments')::text as pancake_bank_payments
from orders x
left join stored s on s.order_id = x.order_id
left join live l on l.order_id = x.order_id
order by x.order_id;
