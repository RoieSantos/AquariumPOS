-- Clears the query statistics that supabase_check_portal_performance.sql reads (pg_stat_statements),
-- so the next check shows only current load - not the paused Pancake sync crons from before
-- 2026-10-24. Changes no data; only resets the counters. Run it, wait a normal working day, then
-- re-run supabase_check_portal_performance.sql.
select extensions.pg_stat_statements_reset();
