-- One-off cleanup before going live with Order Now - clears out test data accumulated while
-- building/testing supabase_automated_orders_tables.sql, supabase_automated_order_session_token.sql,
-- supabase_automated_order_rate_limit.sql, etc. Review before running - this is destructive and not
-- reversible. Does NOT touch Pancake (pos.pages.fm) - any test orders that pushed through there
-- need to be removed separately, on the Pancake side.

-- Deletes every AutomatedOrders row (test orders AO-00001..AO-00071+) and, via the
-- "on delete cascade" FK, all of their AutomatedOrderLines automatically.
delete from public."AutomatedOrders";

-- Test session tokens minted while testing the Order Now link/psid flow.
delete from public."OrderNowSessionTokens";

-- Resets the AO-XXXXX numbering counter, so the first real order after launch starts fresh at
-- AO-00001 instead of continuing from wherever testing left off. Scoped to 'AUTOMATED-ORDER' only
-- - leaves every other series (e.g. TRANSFER-ORDER) untouched.
update public."NoSeriesLine" set "LastNo" = 0 where "SeriesCode" = 'AUTOMATED-ORDER';
