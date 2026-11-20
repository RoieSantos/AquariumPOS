-- Unflag quick replies wrongly marked 💳 "has payment details" - per "Sending shop contact numbers is also
-- sending payment link". The one-time keyword pre-flag (supabase_quick_reply_payment_details.sql) matched
-- our store phone numbers (11 digits, like a GCash no.) and "maya" inside "Amaya" (the branch name), so
-- these replies had their text swapped for the Xendit Pay block and their photos dropped:
--   15 "STORE CP Numbers ##", 31 "contact number" - shop phone numbers only
--   11 "Appreciation" - review links for Amaya / GMA
-- Unflagging also makes the shop numbers "public", so the Send guard stops treating them as payment numbers.
-- Safe to re-run. Ends with every quick reply still flagged.

update public."ChatbotQuickReplies"
   set "HasPaymentDetails" = false
 where "Id" in (11, 15, 31)
   and "HasPaymentDetails";

select q."Id", q."Label", left(q."MessageText", 120) as message_start
  from public."ChatbotQuickReplies" q
 where q."HasPaymentDetails"
 order by q."SortOrder", q."Id";
