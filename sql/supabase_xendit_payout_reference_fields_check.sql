-- READ-ONLY check: which fields does Xendit actually send back on our payouts (Payouts v2)?
-- Xendit support (ticket 2805116, 2026-11-17) says v2 has no recipient-facing reference (InstaPay/PESONet/GCash
-- Ref No.); only v3 adds `processor_reference`, and even that isn't guaranteed to match the recipient's app.
-- This lists every top-level key in the stored "LastResponse" of recent payouts, plus any value whose key
-- looks like a reference, so we can confirm that against real data. Safe to re-run.

with recent as (
  select "PayoutID", "ReferenceID", "XenditPayoutID", "Status", "UpdatedAtUtc", "LastResponse"
    from public."XenditPayouts"
   where "LastResponse" is not null
   order by "UpdatedAtUtc" desc
   limit 20
)
select 'keys seen' as section,
       k.key as field,
       count(*)::text as detail
  from recent r, jsonb_object_keys(r."LastResponse") as k(key)
 group by k.key
union all
select 'reference-like values',
       r."ReferenceID" || ' / ' || k.key,
       left(k.value::text, 200)
  from recent r, jsonb_each(r."LastResponse") as k(key, value)
 where k.key ilike any (array['%ref%', '%processor%', '%trace%', '%rrn%', '%receipt%', 'channel_properties', 'metadata'])
order by 1, 2;
