-- Read-only check: are Xendit webhooks still reaching us? Lists the last 20 online (pay link) payments, newest
-- first, with whether a webhook was ever received for each. Safe to re-run; changes nothing.
--
-- Healthy: Paid rows have webhook_at filled and apply 'Applied', receipt 'Sent'.
-- Problem: a Pending row you know was paid, or recent Paid rows with no webhook_at -> Xendit isn't reaching
-- xendit-webhook (check Xendit Dashboard > Settings > Webhooks > Payment Session URL / callback token, and the
-- webhook delivery log for failed attempts).

select x."CreatedAtUtc" at time zone 'Asia/Manila' as created_ph,
       x."OrderRef" as order_ref,
       x."Status" as status,
       x."ApplyStatus" as apply,
       x."IsTest" as is_test,
       x."Amount" as amount,
       x."PaidAtUtc" at time zone 'Asia/Manila' as paid_ph,
       x."LastWebhookAtUtc" at time zone 'Asia/Manila' as webhook_ph,
       coalesce(x."LastWebhook" ->> 'event', x."LastWebhook" ->> 'source', '(none)') as webhook_event,
       coalesce(x."ReceiptMessageStatus", '(none)') as receipt,
       x."InvoiceID" as xendit_session_id
  from public."XenditPayments" x
 where coalesce(x."Source", 'Online') = 'Online'
 order by x."CreatedAtUtc" desc
 limit 20;
