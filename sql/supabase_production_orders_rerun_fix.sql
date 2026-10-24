-- Fix: "Could not choose the best candidate function between staff_set_production_order_part_done(...)"
-- when a maker taps Production Done (PRD-000090, 2026-10-24).
--
-- Cause: supabase_production_orders.sql was run again (supabase_repair_returns.sql says "Run AFTER" it).
-- That brought back the old 5-argument staff_set_production_order_part_done next to the newer 6-argument
-- one from supabase_production_order_rework.sql (p_reason has a default), so PostgREST can't choose
-- between them. Running it again also undid these, which this file repairs or checks:
--   * ItemLedgerEntries EntryType check lost 'Consumption' (supabase_production_order_consumption.sql),
--     so posting Materials Used would fail. Re-added here.
--   * staff_list_production_order_lines lost colour / sku -> re-run supabase_production_order_lines_sku.sql.
--   * staff_list_production_order_serials lost shelf_spot -> re-run supabase_production_shelf_map.sql, THEN
--     supabase_production_shelf_restore_after_rerun.sql (shelf_map.sql also brings back the oldest shelf
--     functions - the map then shows no racks linked).
--   * _ile_on_reversed: fine if supabase_repair_returns.sql was run after it (checked below).
--
-- Safe to re-run. The result shows OK / FIX for each item.

-- 1. Drop the old 5-arg version. The 6-arg one (p_reason default null) handles every caller.
drop function if exists public.staff_set_production_order_part_done(text, text, text, text, boolean);

-- 2. Allow 'Consumption' again (same list as supabase_production_order_consumption.sql).
do $$
declare
  v_name text;
begin
  for v_name in
    select con.conname
    from pg_constraint con
    where con.conrelid = 'public."ItemLedgerEntries"'::regclass
      and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%EntryType%'
  loop
    execute format('alter table public."ItemLedgerEntries" drop constraint %I', v_name);
  end loop;
end;
$$;

alter table public."ItemLedgerEntries"
  add constraint "CK_ItemLedgerEntries_EntryType"
  check ("EntryType" in ('Purchase', 'Sale', 'Positive Adjmt.', 'Negative Adjmt.', 'Transfer', 'Output', 'Consumption'));

notify pgrst, 'reload schema';

-- Verification - one result.
select 'part_done versions (want 1)' as section,
       case when count(*) = 1 then 'OK' else 'FIX' end as result,
       string_agg(pg_get_function_identity_arguments(p.oid), ' | ') as detail
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'staff_set_production_order_part_done'
union all
select 'EntryType allows Consumption',
       case when bool_or(pg_get_constraintdef(c.oid) ilike '%Consumption%') then 'OK' else 'FIX' end,
       null
  from pg_constraint c
 where c.conrelid = 'public."ItemLedgerEntries"'::regclass and c.contype = 'c'
union all
select 'order lines return sku (else re-run lines_sku)',
       case when bool_or(pg_get_function_result(p.oid) ilike '%sku text%') then 'OK' else 'FIX' end,
       null
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'staff_list_production_order_lines'
union all
select 'order serials return shelf_spot (else re-run shelf_map)',
       case when bool_or(pg_get_function_result(p.oid) ilike '%shelf_spot%') then 'OK' else 'FIX' end,
       null
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'staff_list_production_order_serials'
union all
select '_ile_on_reversed has Repair guard (else re-run repair_returns)',
       case when bool_or(pg_get_functiondef(p.oid) ilike '%Repair Shipment%') then 'OK' else 'FIX' end,
       null
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = '_ile_on_reversed';
