-- ONE-OFF: cancel TEST order AO-00050 (bot / GMA order). Run as a whole in the Supabase SQL editor.
--
-- - AutomatedOrders: Status -> 'Cancelled' (same as the "Cancel Order" button on the New tab), so it drops
--   off New / GMA Conversations.
-- - OnlineOrders (only if it was already confirmed into Online Orders as OrderID 'AO-00050'): Status ->
--   'Cancelled'. _ile_order_counts_as_sale treats 'Cancelled' as not-a-sale, so the Item Ledger reconcile
--   posts the opposite entries for anything it already took out of stock (nothing is deleted - ledger rows
--   stay, the reversal nets them to 0). The reconcile is run right here instead of waiting for the cron.
-- Nothing is deleted. Portal-only order - no Pancake call involved. Safe to re-run.

do $$
declare
  v_bot int;
  v_online int;
begin
  update public."AutomatedOrders"
     set "Status" = 'Cancelled', "UpdatedBy" = 'sql-test-cleanup', "UpdatedAtUtc" = now()
   where "OrderNo" = 'AO-00050';
  get diagnostics v_bot = row_count;

  update public."OnlineOrders"
     set "Status" = 'Cancelled'
   where "OrderID" = 'AO-00050';
  get diagnostics v_online = row_count;

  if v_bot = 0 and v_online = 0 then
    raise exception 'AO-00050 not found in AutomatedOrders or OnlineOrders - nothing changed.';
  end if;

  if v_online > 0 then
    perform public._ile_reconcile_online_order('AO-00050');
  end if;
end $$;

-- Result: bot order status, online order status, and net stock movement on the ledger (should be 0).
select 'bot order' as section, o."Status"::text as status, null::text as net_ledger_qty
from public."AutomatedOrders" o where o."OrderNo" = 'AO-00050'
union all
select 'online order', o."Status"::text,
       (select coalesce(sum(e."Quantity"), 0)::text from public."ItemLedgerEntries" e
         where e."DocumentNo" = 'AO-00050')
from public."OnlineOrders" o where o."OrderID" = 'AO-00050';
