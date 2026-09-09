-- Follow-up to the Order Now confirmation screen's Online Order ID not landing within the
-- customer-facing poll window (pollAutomatedOrderPancakeStatus in js/orderNow.js, currently 16
-- tries x 2.5s = 40s) for AO-00068/AO-00069/AO-00071. This shows exactly what happened server-side
-- for each: how long the push actually took (PancakeLastAttemptAtUtc - CreatedAtUtc), whether it
-- ultimately succeeded/failed/is still Pending, and the real error text if it failed - so we can
-- tell whether this is purely a "40s wasn't long enough" tuning problem, or an actual recurring
-- push failure the reassuring UI text has been quietly papering over. Safe to re-run, read-only.

select
  "OrderNo",
  "PancakeSyncStatus",
  "PancakeOrderId",
  "PancakeSyncError",
  "CreatedAtUtc",
  "PancakeLastAttemptAtUtc",
  extract(epoch from ("PancakeLastAttemptAtUtc" - "CreatedAtUtc")) as seconds_from_create_to_last_attempt,
  "ConfirmationMessageStatus",
  "ConfirmationMessageError"
from public."AutomatedOrders"
order by "CreatedAtUtc" desc
limit 15;
