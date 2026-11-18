-- Read-only check: Marvin Cayangho's "Unable to Pay" PHP 180.00 QR Ph (bank app, 2026-11-18 09:26 AM PH).
-- Lists every Xendit payment for PHP 180 created 2026-11-17 onward, newest first, so we can see whether the QR
-- he scanned was still open, or already Expired / cancelled (e.g. replaced by a newer session) before 09:26.
-- Safe to re-run; changes nothing.

select x."CreatedAtUtc" at time zone 'Asia/Manila' as created_ph,
       x."OrderRef" as order_ref,
       coalesce(x."Source", 'Online') as source,
       x."Status" as status,
       x."ApplyStatus" as apply,
       x."IsTest" as is_test,
       x."Amount" as amount,
       x."PaidAtUtc" at time zone 'Asia/Manila' as paid_ph,
       x."LastWebhookAtUtc" at time zone 'Asia/Manila' as webhook_ph,
       coalesce(x."LastWebhook" ->> 'event', x."LastWebhook" ->> 'source', '(none)') as webhook_event,
       x."InvoiceID" as xendit_id
  from public."XenditPayments" x
 where x."Amount" = 180
   and x."CreatedAtUtc" >= timestamptz '2026-11-17 00:00:00+08'
 order by x."CreatedAtUtc" desc;
