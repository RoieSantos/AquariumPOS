-- Read-only check: Vic told the customer of AO-00121 "naayos ko na po - P2,999 lang (set + dual stand, all-in)"
-- but the order still has the DUALSTAND line (P4,289). modify_order re-prices every line from the catalog and
-- stamps "[Vic changed the order ...]" into Notes when it saves, so:
--   - no change note / old UpdatedAtUtc  -> the bot never applied a change (it only said it did),
--   - SET-019 package rows               -> whether the 15G set itself includes a stand (ad photo shows one).
-- Change the order no. below to check another one. Safe to re-run.

with q as (select 'AO-00121'::text as ord, 'SET-019'::text as set_code)
select 'order' as section, o."OrderNo"::text as ref,
       concat('status=', o."Status", ', sync=', o."PancakeSyncStatus", ', total=', o."EstimatedTotal",
              ', updated=', to_char(o."UpdatedAtUtc" at time zone 'Asia/Manila', 'MM-DD HH24:MI'))::text as detail,
       coalesce(o."Notes", '')::text as extra
  from public."AutomatedOrders" o, q where o."OrderNo" = q.ord
union all
select 'order line', l."ItemCode"::text, concat(l."ItemName", ' x', l."Quantity", ' @ ', l."Price")::text, null
  from public."AutomatedOrderLines" l, q where l."OrderNo" = q.ord
union all
select 'set package', s.code, concat(s.name, ' @ ', s.price)::text,
       concat('includes=', s.includes::text, ' | store_selected=', s.store_selected::text,
              ' | not_included=', s.not_included::text, ' | desc=', left(coalesce(s.description, ''), 400))::text
  from public.public_list_aquarium_sets() s, q where s.code = q.set_code
union all
select 'chat ' || m."Role", to_char(m."CreatedAtUtc" at time zone 'Asia/Manila', 'MM-DD HH24:MI:SS'),
       left(m."Content", 1500)::text, null
  from public."ChatbotMessages" m
  join public."AutomatedOrders" o on o."Psid" = m."Psid", q
 where o."OrderNo" = q.ord
   and m."CreatedAtUtc" >= o."CreatedAtUtc" - interval '3 hours'
order by 1, 2;
