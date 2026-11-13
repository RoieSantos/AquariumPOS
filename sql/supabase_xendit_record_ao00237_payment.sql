-- One-off: record AO-00237's ₱535 Xendit down payment that Xendit took but never told us about.
--
-- What happened: the customer had a QR Ph code on screen (session ps-6af693d3ada4a7646ee8db77, our payment
-- 03ac9c00), reopened the pay link (which cancelled that session and marked it Expired here), then paid the old
-- QR at 12:37 PM anyway. Xendit only sent payment.capture, and the Payment Requests V3 "Payment Status" webhook
-- URL was not set, so it never reached xendit-webhook. Details below are from the Xendit dashboard transaction
-- (Successful, PHP 535, QRPH, payment request pr-878c3847-..., payment py-56b33fc5-...).
--
-- Records it the normal way (_xendit_record_invoice_status -> Paid + applied to the order once). Does NOT send
-- the Messenger receipt (SQL can't reach Facebook): staff send the receipt link from Conversations, then press
-- Confirm Order (allowed now that the order has a real payment).
-- Safe to re-run: a payment already Paid is never applied twice.

select public._xendit_record_invoice_status(
  jsonb_build_object(
    'id', 'ps-6af693d3ada4a7646ee8db77',
    'external_id', 'RSPS-AO-00237-03ac9c00',
    'status', 'PAID',
    'amount', 535,
    'paid_amount', 535,
    'payment_method', 'QRPH',
    'payment_channel', 'QRPH',
    'payment_id', 'py-56b33fc5-824d-8610-aae0-a76878e27173',
    'paid_at', '2026-11-13T04:37:38Z'
  ),
  jsonb_build_object('source', 'manual - AO-00237 paid on a cancelled session, payment.capture webhook URL was not set',
                     'payment_request_id', 'pr-878c3847-5be7-8600-8ff2-2d1fbf43ab39')
) as result,
'https://rspetstop.com/payment-receipt.html?id=03ac9c00-7d0a-465e-9029-0dc3e94fea67' as receipt_link;
