-- Read-only check: Online Pay refused a payment with "The payment (1.00) is more than the balance in
-- Pancake (0.00)" although the Online Pay screen showed a balance to pay.
--
-- Shows, for one order:
--   portal             - what Online Pay's lookup shows (OnlineOrders: MoneyToCollect / AmountPaid / Balance)
--   pancake raw        - every payment-looking field Pancake returns for the order right now
--   online pay reads   - what pos_record_online_order_payment parsed from it (money, prepaid, cash, bank)
--   online pay balance - money - prepaid = the balance it checked the payment against
-- If "pancake raw" says the order is paid, the portal copy was stale and the block was right. If not,
-- Online Pay is reading the wrong fields.
--
-- Change the order id on the line below. Makes one Pancake GET; changes nothing. Run after
-- supabase_pos_online_pay.sql.

with p as (select 'ORDER-ID'::text as order_id),
live as (select public._pos_pay_pancake_get((select order_id from p)) as el),
st as (select el, public._pos_pay_pancake_state(el) as s from live)
select 'portal' as section, f.k as field, f.v as value
from public."OnlineOrders" o
join p on o."OrderID" = p.order_id
cross join lateral (values
  ('Status', o."Status"),
  ('Source', to_jsonb(o) ->> 'Source'),
  ('MoneyToCollect', o."MoneyToCollect"::text),
  ('AmountPaid', o."AmountPaid"::text),
  ('Balance', o."Balance"::text),
  ('SyncedAtUtc', o."SyncedAtUtc"::text)
) as f(k, v)
union all
select 'pancake', 'order found in Pancake', case when el is null then 'NO - portal only (Online Pay records it on the portal)' else 'yes' end
from st
union all
select 'pancake raw', k.key, left(k.value::text, 200)
from st, jsonb_each(st.el) k
where k.key ~* '(money|prepaid|paid|cash|bank|cod|total|discount|shipping|fee|transfer|deposit|status)'
union all
select 'online pay reads', k.key, k.value::text
from st, jsonb_each(st.s) k
union all
select 'online pay balance', 'money - prepaid',
       (coalesce((s ->> 'money')::numeric, 0) - coalesce((s ->> 'prepaid')::numeric, 0))::text
from st
order by 1, 2;
