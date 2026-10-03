-- Read-only: who changed order 105852's status in Pancake, and when - one row per Pancake history entry
-- (newest first). Per "once I do ready-to ship it is not deducting the serials": the order has 0 serials
-- tied to it (supabase_check_order_105852_serials.sql), so the 9:57 AM To Ship didn't go through the
-- portal's serial picker. The editor name / app here shows where it came from (desktop POS, Pancake,
-- or the portal - the portal writes through the shop API key).
-- changed = the history entry's own fields (status old -> new, etc.), shortened.

with resp as (
  select extensions.http_get(
    'https://pos.pages.fm/api/v1/shops/1328301944/orders/105852?api_key=' || public._pancake_api_key()
  ) as r
),
el as (
  select case when jsonb_typeof((r).content::jsonb -> 'data') = 'object' then (r).content::jsonb -> 'data'
              else (r).content::jsonb end as o
  from resp
),
h as (
  select x.entry, x.n
  from el,
       jsonb_array_elements(case when jsonb_typeof(el.o -> 'histories') = 'array' then el.o -> 'histories' else '[]'::jsonb end)
         with ordinality as x(entry, n)
)
select
  coalesce(h.entry ->> 'updated_at', h.entry ->> 'inserted_at', h.entry ->> 'created_at') as at_utc,
  coalesce(h.entry -> 'editor' ->> 'name', h.entry ->> 'editor_name', h.entry ->> 'editor_id', h.entry ->> 'user_id', '-') as editor,
  coalesce(h.entry ->> 'app', h.entry ->> 'source', h.entry ->> 'platform', '-') as via,
  coalesce(h.entry ->> 'status', '-') as status,
  left((h.entry - 'editor')::text, 600) as changed
from h
order by h.n desc;
