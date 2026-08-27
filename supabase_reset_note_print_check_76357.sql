-- One-off fix for Order #76357 (Leo Lagon): its "NotePrint" was checked once on 2026-08-25 and
-- cached as null forever (see the "compute once, cache forever" design comment on the
-- "GlassThickness"/"NotePrint" columns in supabase_orders_sync_tables.sql) - but Pancake's own
-- note_print for this order was edited on 2026-08-27 ("AM Delivery before 12...Installation of
-- pipes and Leak Testing included on setup", confirmed via the raw Pancake payload), well AFTER
-- that one-time check. Nothing in this system automatically re-checks an order once
-- "NotePrintCheckedAt" is set, even if Pancake's own note changes later - clearing it back to
-- null re-qualifies this order for cron_sync_online_orders_from_pancake's note/glass backfill
-- loop (supabase_pancake_manual_sync.sql), which runs every minute and will pick this order back
-- up on its very next pass (ordered by Last_Updated_At desc, so a recently-touched order like
-- this one goes near the front of the queue).

update public."OnlineOrders"
set "NotePrintCheckedAt" = null
where "OrderID" = '76357';
