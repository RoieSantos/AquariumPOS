-- READ-ONLY diagnostic: what is eating the Disk IO budget ("Your project is about to deplete its Disk IO Budget")?
--
-- Changes nothing. One result: section / rank / item / detail.
--   0 Stats window      - how long the counters below have been collecting (since last stats reset)
--   1 Top reads         - queries that pull the most 8 KB blocks from disk (cache misses = real disk reads)
--   2 Top writes        - queries that dirty/write the most blocks (incl. temp files from big sorts/hashes)
--   3 Table disk reads  - tables whose data/indexes are read from disk the most
--   4 Seq scans         - tables read end-to-end most often (usually a missing index on a cron job's filter)
--   5 Churn / bloat     - tables with the most inserts/updates/deletes and dead rows (vacuum work = disk writes)
--   6 Cron (24h)        - each cron job's runs, total and max time over the last 24h
--   7 Log tables        - size of the cron run log and pg_net response log
--   8 Database          - cache hit ratio and temp file usage overall

with stmts as (
  select regexp_replace(left(s.query, 200), '\s+', ' ', 'g') as q,
         s.calls, s.total_exec_time, s.shared_blks_read, s.shared_blks_hit,
         s.shared_blks_dirtied, s.shared_blks_written, s.temp_blks_written,
         row_number() over (order by s.shared_blks_read desc) as rk_read,
         row_number() over (order by (s.shared_blks_dirtied + s.shared_blks_written + s.temp_blks_written) desc) as rk_write
  from extensions.pg_stat_statements s
  where s.dbid = (select oid from pg_database where datname = current_database())
),
tbl as (
  select t.schemaname || '.' || t.relname as name, t.relid,
         t.n_live_tup, t.n_dead_tup, t.seq_scan, t.seq_tup_read, coalesce(t.idx_scan, 0) as idx_scan,
         t.n_tup_ins, t.n_tup_upd, t.n_tup_del, t.last_autovacuum, t.autovacuum_count,
         coalesce(io.heap_blks_read, 0) + coalesce(io.idx_blks_read, 0)
           + coalesce(io.toast_blks_read, 0) + coalesce(io.tidx_blks_read, 0) as blks_read,
         row_number() over (order by coalesce(io.heap_blks_read, 0) + coalesce(io.idx_blks_read, 0)
           + coalesce(io.toast_blks_read, 0) + coalesce(io.tidx_blks_read, 0) desc) as rk_read,
         row_number() over (order by t.seq_tup_read desc) as rk_seq,
         row_number() over (order by (t.n_tup_ins + t.n_tup_upd + t.n_tup_del) desc) as rk_churn
  from pg_stat_user_tables t
  left join pg_statio_user_tables io on io.relid = t.relid
),
cron24 as (
  select j.jobname, j.schedule, count(*) as runs,
         count(*) filter (where d.status = 'failed') as failed,
         sum(d.end_time - d.start_time) as total_time,
         max(d.end_time - d.start_time) as max_time,
         row_number() over (order by sum(d.end_time - d.start_time) desc nulls last) as rk
  from cron.job_run_details d
  join cron.job j on j.jobid = d.jobid
  where d.start_time > now() - interval '24 hours'
  group by j.jobname, j.schedule
)

select '0 Stats window' as section, 1 as rank, 'pg_stat_statements since' as item,
       coalesce((select stats_reset::text from extensions.pg_stat_statements_info), '?')
       || ' (' || coalesce((select date_trunc('minute', now() - stats_reset)::text from extensions.pg_stat_statements_info), '?') || ' ago)' as detail
union all
select '0 Stats window', 2, 'table/database stats since',
       coalesce((select stats_reset::text from pg_stat_database where datname = current_database()), 'server start')

union all
select '1 Top reads', rk_read::int, left(q, 120),
       pg_size_pretty(shared_blks_read * 8192) || ' read from disk; ' || calls || ' calls; '
       || round((total_exec_time / 1000)::numeric, 1) || 's total; cache hit '
       || coalesce(round(100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0), 1)::text, '?') || '%'
from stmts where rk_read <= 15

union all
select '2 Top writes', rk_write::int, left(q, 120),
       pg_size_pretty(shared_blks_dirtied * 8192) || ' dirtied; ' || pg_size_pretty(shared_blks_written * 8192)
       || ' written; ' || pg_size_pretty(temp_blks_written * 8192) || ' temp; ' || calls || ' calls'
from stmts where rk_write <= 15

union all
select '3 Table disk reads', rk_read::int, name,
       pg_size_pretty(blks_read * 8192) || ' read from disk; table size ' || pg_size_pretty(pg_total_relation_size(relid))
from tbl where rk_read <= 15

union all
select '4 Seq scans', rk_seq::int, name,
       seq_scan || ' full scans reading ' || seq_tup_read || ' rows (vs ' || idx_scan || ' index scans); '
       || n_live_tup || ' rows, ' || pg_size_pretty(pg_total_relation_size(relid))
from tbl where rk_seq <= 15

union all
select '5 Churn / bloat', rk_churn::int, name,
       'ins ' || n_tup_ins || ' / upd ' || n_tup_upd || ' / del ' || n_tup_del || '; dead rows ' || n_dead_tup
       || ' of ' || n_live_tup || ' live; autovacuums ' || autovacuum_count
       || '; last ' || coalesce(date_trunc('minute', last_autovacuum)::text, 'never')
from tbl where rk_churn <= 15

union all
select '6 Cron (24h)', rk::int, jobname || ' [' || schedule || ']',
       runs || ' runs, ' || failed || ' failed; total ' || coalesce(date_trunc('second', total_time)::text, '?')
       || '; longest ' || coalesce(date_trunc('second', max_time)::text, '?')
from cron24

union all
select '7 Log tables', 1, 'cron.job_run_details',
       (select count(*) from cron.job_run_details)::text || ' rows; ' || pg_size_pretty(pg_total_relation_size('cron.job_run_details'))
       || '; oldest ' || coalesce((select min(start_time)::text from cron.job_run_details), 'none')
union all
select '7 Log tables', 2, 'net._http_response',
       coalesce(pg_size_pretty(pg_total_relation_size(to_regclass('net._http_response'))), 'not present')

union all
select '8 Database', 1, 'cache hit ratio / disk reads / temp files',
       round(100.0 * blks_hit / nullif(blks_hit + blks_read, 0), 2) || '% hit; ' || pg_size_pretty(blks_read * 8192)
       || ' read from disk; ' || temp_files || ' temp files (' || pg_size_pretty(temp_bytes) || ')'
from pg_stat_database where datname = current_database()
union all
select '8 Database', 2, 'database size', pg_size_pretty(pg_database_size(current_database()))

order by 1, 2;
