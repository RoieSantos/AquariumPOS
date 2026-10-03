-- Read-only: is a portal status change zeroing Amount Paid? Per "i found another 1 again" - order 106916
-- (To Ship) shows Paid Via GCASH 840.00 but Amount Paid 0.00 / Balance 840.00, same as 105852 did.
--
-- SUSPECTED CAUSE: the portal's Amount Paid is Pancake's "prepaid" field, while Paid Via is
-- bank_payments. A portal status change (_pancake_patch_online_order_status) PATCHes Pancake, which wipes
-- bank_payments (and, it seems, the prepaid total built from them). The keep-payments fix then writes
-- ONLY bank_payments back - prepaid stays 0, so Paid Via comes back but Amount Paid doesn't.
--
-- One short row per order (fits one screenshot): 105852, 106916 and every other order whose Paid Via
-- (OnlineOrderPayments) adds up to more than its Amount Paid (up to 25). Pancake columns are read live:
--   prepaid / cash / transfer / bank (sum of bank_payments) / cod / to_collect (money_to_collect) / total
-- then the portal's paid / balance, and snaps = how many status-change snapshots the portal took.

with paid_via as (
  select "OrderID", sum("Amount") as paid_via
  from public."OnlineOrderPayments"
  group by "OrderID"
),
ids as (
  select order_id from (values ('105852'), ('106916')) v(order_id)
  union
  (select o."OrderID"
   from public."OnlineOrders" o
   join paid_via pv on pv."OrderID" = o."OrderID"
   where pv.paid_via > coalesce(o."AmountPaid", 0) + 0.009
   order by o."OrderID" desc
   limit 25)
),
el as (
  select i.order_id,
         case when jsonb_typeof((r).content::jsonb -> 'data') = 'object' then (r).content::jsonb -> 'data'
              else (r).content::jsonb end as o
  from ids i,
       lateral (select extensions.http_get(
         'https://pos.pages.fm/api/v1/shops/1328301944/orders/' || i.order_id || '?api_key=' || public._pancake_api_key()
       ) as r) x
)
select el.order_id,
       po."Status" as status,
       el.o ->> 'prepaid' as prepaid,
       el.o ->> 'cash' as cash,
       el.o ->> 'transfer_money' as transfer,
       (select sum(public.pancake_parse_decimal(b.value))
        from jsonb_each_text(case when jsonb_typeof(el.o -> 'bank_payments') = 'object' then el.o -> 'bank_payments' else '{}'::jsonb end) b) as bank,
       el.o ->> 'cod' as cod,
       el.o ->> 'money_to_collect' as to_collect,
       el.o ->> 'total_price' as total,
       po."AmountPaid" as paid,
       po."Balance" as balance,
       (select count(*) from public."PancakeBankPaymentSnapshots" s where s."OrderID" = el.order_id) as snaps
from el
left join public."OnlineOrders" po on po."OrderID" = el.order_id
order by el.order_id desc;
