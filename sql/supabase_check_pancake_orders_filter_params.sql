-- Read-only probe: which /orders query params does Pancake actually honor for "only orders changed since X"?
-- supabase_online_orders_sync_timeout_fix.sql showed Pancake IGNORES the sync's updated_after/created_after/
-- since params (total_entries=8057 = every order), so each every-minute cron run walks all ~81 pages -
-- fine at ~0.5s/page, but at today's ~1.9s/page that blew past the 2-min statement timeout.
--
-- Asks Pancake for page 1 (page_size=1) with each candidate filter, all set to "changed in the last
-- 2 hours". A variant whose total_entries is small (tens, not ~8000) is a filter Pancake honors - the
-- cron can then switch to it. ~5 Pancake calls, each a few seconds. Safe to run any time. ONE result.

with
t0 as materialized (
  select extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000') is not null as ok,
         extract(epoch from now() - interval '2 hours')::bigint as since_unix,
         extract(epoch from now())::bigint as now_unix,
         to_char((now() - interval '2 hours') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') as since_iso
),
v as (
  select * from t0, lateral (values
    ('a no filter', ''),
    ('b updated_after (current sync)', '&updated_after=' || since_iso),
    ('c startDateTime+updateStatus=updated_at', '&updateStatus=updated_at&startDateTime=' || since_unix || '&endDateTime=' || now_unix),
    ('d startDateTime only (created)', '&startDateTime=' || since_unix || '&endDateTime=' || now_unix),
    ('e update_status=updated_at + start/end', '&update_status=updated_at&start_date_time=' || since_unix || '&end_date_time=' || now_unix)
  ) x(variant, qs)
),
r as materialized (
  select v.variant, h.status, h.content
  from v, lateral extensions.http_get('https://pos.pages.fm/api/v1/shops/1328301944/orders?api_key='
         || public._pancake_api_key() || '&page_size=1&page=1' || v.qs
         || case when v.ok then '' else '' end) h
)
select variant as section,
       'HTTP ' || status as item,
       case when status between 200 and 299 then
         'total_entries=' || coalesce(content::jsonb ->> 'total_entries', content::jsonb ->> 'total', '?')
         || ' | first updated_at=' || coalesce(content::jsonb -> 'data' -> 0 ->> 'updated_at', '?')
       else 'ERROR - ' || left(coalesce(content, ''), 150) end as detail
from r
order by 1;
