-- Read-only: why "We could not start the online payment" on AO-00204. Lists the order's Xendit attempts, newest
-- first. CreateError holds Xendit's own reason when the session was refused (e.g. amount below a channel minimum).
-- No rows at all = it failed before an attempt row was made (mode check / old-invoice expiry / card fee step).
select "CreatedAtUtc", "Status", "Purpose", "Amount", "IsTest", "InvoiceID", "CreateError"
  from public."XenditPayments"
 where 'AO-00204' in ("OrderRef", "AutomatedOrderNo", "OnlineOrderID")
 order by "CreatedAtUtc" desc
 limit 10;
