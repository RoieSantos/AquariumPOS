-- Read-only: what Pancake itself says about order 105852's payment, next to what the portal has.
-- After the GCASH 501.00 was put back (supabase_restore_payment_105852.sql) Paid Via shows GCASH 501.00
-- (read live from bank_payments) but Amount Paid stayed 0.00 - the portal's Amount Paid is copied from
-- Pancake's "prepaid" field. This shows whether Pancake's prepaid is still 0 (Pancake didn't recompute it
-- from bank_payments) or the portal just hasn't re-read it, plus every other payment-looking field
-- Pancake returns, so the right one can be used.

with resp as (
  select extensions.http_get(
    'https://pos.pages.fm/api/v1/shops/1328301944/orders/105852?api_key=' || public._pancake_api_key()
  ) as r
),
el as (
  select case when jsonb_typeof((r).content::jsonb -> 'data') = 'object' then (r).content::jsonb -> 'data'
              else (r).content::jsonb end as o,
         (r).status as http_status
  from resp
)
select 'pancake' as source, k.key as field, k.value::text as value, el.http_status::text as note
from el, jsonb_each(el.o) k
where k.key ~* '(paid|pay|prepaid|cash|bank|cod|money|total|transfer|deposit|discount|shipping|surcharge|fee|updated_at)'
union all
select 'portal', f.field, f.value, null
from public."OnlineOrders" o,
     lateral (values
       ('MoneyToCollect', o."MoneyToCollect"::text),
       ('AmountPaid', o."AmountPaid"::text),
       ('Balance', o."Balance"::text),
       ('Last_Updated_At', o."Last_Updated_At"::text),
       ('SyncedAtUtc', o."SyncedAtUtc"::text)
     ) as f(field, value)
where o."OrderID" = '105852'
order by 1 desc, 2;
