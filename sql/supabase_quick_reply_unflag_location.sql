-- Unflag the "Location" quick reply - per "is supposed to be location but now it has the payment links".
-- supabase_quick_reply_payment_details.sql pre-flagged quick replies by keyword / any 10+ digit number, so
-- Location (store phone number) got the 💳 flag. While Xendit is live a flagged reply has its "number" lines
-- swapped for the Pay link and its photos (the map) dropped. The message text itself was never changed.
--
-- Safe to re-run. Ends with ONE result: every quick reply that is still flagged, so you can spot other
-- false positives (unflag them with the 💳 button in Manage Quick Replies).

update public."ChatbotQuickReplies"
   set "HasPaymentDetails" = false
 where trim("Label") ilike 'location%';

select q."Id", q."Label", q."HasPaymentDetails", left(q."MessageText", 200) as message_start
  from public."ChatbotQuickReplies" q
 where q."HasPaymentDetails" or trim(q."Label") ilike 'location%'
 order by q."HasPaymentDetails" desc, q."SortOrder", q."Id";
