-- Read-only check: why did a Xendit-paid order get no "Payment received" message / receipt link in Conversations?
-- Change the order number in the first CTE and run the whole file. Safe to re-run; changes nothing.
--
-- What to look for:
--   payment       - Status should be Paid, ApplyStatus Applied, ReceiptMessageStatus Sent.
--                   ReceiptMessageStatus empty + Applied  -> the webhook never sent it (e.g. applied later by "Retry",
--                                                           or the webhook call that saw it Paid didn't apply it).
--                   'No chat'                            -> order has no GmaPsid / conversation.
--                   'Failed: ...'                        -> Facebook refused it (reason shown).
--                   ApplyStatus Failed                   -> ApplyError says why; no message is sent until applied.
--   order         - GmaPsid / page the message would go to ('web:...' = Alice website widget chat).
--   receipt_msg   - the ChatbotMessages row the claim wrote (if any).
--   webhook       - the last Xendit callback seen for each payment.
--   receipt_fn    - whether the live _xendit_claim_receipt_message includes the receipt link.

with o as (select 'AO-00237'::text as order_no),
pay as (
  select x.* from public."XenditPayments" x, o
   where x."AutomatedOrderNo" = o.order_no or x."OrderRef" = o.order_no
)
select 'payment' as section,
       p."CreatedAtUtc" as at_utc,
       concat_ws(' | ',
         'id ' || p."PaymentID",
         'status ' || p."Status",
         'apply ' || p."ApplyStatus" || coalesce(' (' || p."ApplyError" || ')', ''),
         'test ' || p."IsTest",
         'purpose ' || p."Purpose",
         'amount ' || p."Amount",
         'paid ' || coalesce(p."PaidAmount"::text, '-') || ' at ' || coalesce(p."PaidAtUtc"::text, '-'),
         'applied at ' || coalesce(p."AppliedAtUtc"::text, '-'),
         'receipt msg ' || coalesce(p."ReceiptMessageStatus", '(none)') || ' at ' || coalesce(p."ReceiptMessageAtUtc"::text, '-'),
         'msg id ' || coalesce(p."ReceiptMessageId"::text, '-')) as detail
  from pay p
union all
select 'webhook', p."LastWebhookAtUtc",
       concat_ws(' | ', 'id ' || p."PaymentID", 'event ' || coalesce(p."LastWebhook" ->> 'event', '-'),
                 left(coalesce(p."LastWebhook"::text, '(no webhook received)'), 600))
  from pay p
union all
select 'order', a."CreatedAtUtc",
       concat_ws(' | ', 'order ' || a."OrderNo", 'status ' || coalesce(a."Status", '-'),
                 'sync ' || coalesce(a."PancakeSyncStatus", '-'),
                 'psid ' || coalesce(nullif(trim(a."GmaPsid"), ''), '(none)'),
                 'page ' || coalesce(nullif(trim(a."GmaPageId"), ''), '(none)'),
                 'has conversation ' || exists (select 1 from public."ChatbotConversations" c where c."Psid" = a."GmaPsid"),
                 'customer ' || coalesce(a."CustomerName", '-'))
  from public."AutomatedOrders" a, o
 where a."OrderNo" = o.order_no
union all
select 'receipt_msg', m."CreatedAtUtc",
       concat_ws(' | ', 'msg ' || m."Id", 'by ' || coalesce(m."SentByUsername", '-'),
                 'delivery ' || coalesce(m."DeliveryStatus", '-'), left(m."Content", 300))
  from public."ChatbotMessages" m
 where m."Id" in (select "ReceiptMessageId" from pay)
    or (m."SentByUsername" = 'Xendit'
        and m."Psid" = (select a."GmaPsid" from public."AutomatedOrders" a, o where a."OrderNo" = o.order_no))
union all
select 'receipt_fn', null,
       case when position('payment-receipt.html' in pg_get_functiondef('public._xendit_claim_receipt_message(uuid)'::regprocedure)) > 0
            then 'live function includes the receipt link' else 'OLD VERSION - no receipt link' end
union all
select 'no_payment', null, 'No XenditPayments row for this order'
 where not exists (select 1 from pay)
order by section, at_utc nulls last;
