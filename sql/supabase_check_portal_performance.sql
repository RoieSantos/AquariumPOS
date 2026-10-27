-- Read-only performance diagnostic for the staff portal (2026-10-27). Safe to re-run; changes nothing.
-- Shows where the database's time actually goes: the busiest RPCs (calls, avg ms, total seconds,
-- share of all DB time) from pg_stat_statements, plus active cron jobs, connections, cache hit
-- ratio and the size of the tables the slow pages read. One result set (section column).
with stmts as (
  select
    coalesce(
      substring(query from '"public"\."([A-Za-z0-9_]+)"\('),
      substring(query from 'public\.([A-Za-z0-9_]+)\('),
      left(regexp_replace(query, '\s+', ' ', 'g'), 70)
    ) as fn,
    calls,
    total_exec_time,
    rows
  from extensions.pg_stat_statements
),
by_fn as (
  select fn, sum(calls) as calls, sum(total_exec_time)::numeric as total_ms, sum(rows) as rows
  from stmts
  group by fn
),
grand as (select sum(total_ms) as all_ms from by_fn),
top_fn as (
  select b.*, row_number() over (order by b.total_ms desc) as rn
  from by_fn b
  order by b.total_ms desc
  limit 30
)
select * from (
  select 1 as ord, 0 as rn, 'stats window'::text as section,
         'pg_stat_statements since'::text as item,
         coalesce((select stats_reset::text from extensions.pg_stat_statements_info), 'unknown') as value,
         'numbers below are cumulative since this time'::text as detail

  union all
  select 2, t.rn, 'top RPCs by total DB time', t.fn,
         round(t.total_ms / 1000.0, 1)::text || ' s total',
         t.calls::text || ' calls, avg ' || round((t.total_ms / nullif(t.calls, 0))::numeric, 1)::text
           || ' ms, ' || round((100.0 * t.total_ms / nullif(g.all_ms, 0))::numeric, 1)::text || '% of all DB time'
  from top_fn t cross join grand g

  union all
  select 3, 0, 'cron jobs (active)', j.jobname::text, j.schedule::text, left(j.command, 120)
  from cron.job j
  where j.active

  union all
  select 4, 0, 'connections', coalesce(a.state, '(background)'), count(*)::text, 'from pg_stat_activity'
  from pg_stat_activity a
  group by a.state

  union all
  select 5, 0, 'settings', s.name::text, s.setting || coalesce(' ' || s.unit, ''), ''
  from pg_settings s
  where s.name in ('max_connections', 'shared_buffers', 'work_mem', 'effective_cache_size')

  union all
  select 6, 0, 'cache hit ratio', 'tables (should be > 99%)',
         round((100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0))::numeric, 2)::text || '%',
         ''
  from pg_statio_user_tables

  union all
  select 7, 0, 'table sizes', c.relname::text,
         to_char(greatest(c.reltuples, 0)::bigint, 'FM999,999,999') || ' rows (est.)',
         pg_size_pretty(pg_total_relation_size(c.oid))
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  where c.relkind = 'r'
    and c.relname in ('ChatbotConversations', 'ChatbotMessages', 'OnlineOrders', 'OnlineOrderLines',
                      'AutomatedOrders', 'StaffUsers', 'ItemLedgerEntries')
) r
order by ord, rn, section, item;
