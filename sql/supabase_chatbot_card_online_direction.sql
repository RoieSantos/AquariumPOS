-- Alice / Vic: card payments are now online too - per "teach the aibot now that we can now accept payment via
-- credit card online and no need to go to the physical stores".
--
-- The AI Settings "Custom Directions" (ChatbotAiSettings."CustomDirections", typed by the owner) said
-- "- CARD payment now accepting at all branch (5% fee per transaction)", which sends card customers to a
-- branch. This swaps only that one line; everything else in Custom Directions is left as typed. The bot's own
-- prompt (chatbot-engine.ts, CARD PAYMENTS ONLINE) already says cards are paid through the pay link while
-- online payment is live, with the fee from the Xendit Payments page.
--
-- Safe to re-run (does nothing once the line is already replaced). You can also edit the line yourself in AI
-- Settings instead.

update public."ChatbotAiSettings"
   set "CustomDirections" = regexp_replace(
         "CustomDirections",
         '-[ ]*CARD payment now accepting at all branch[^\n]*',
         '- CARD payment (Visa / Mastercard / JCB) accepted ONLINE through the pay link - no need to visit a branch - and at all branches (card fee shown on the pay page)'),
       "UpdatedAtUtc" = now()
 where "CustomDirections" ~ 'CARD payment now accepting at all branch';

-- Check - one result: the card line(s) now in Custom Directions.
select s."Id", line
  from public."ChatbotAiSettings" s,
       regexp_split_to_table(s."CustomDirections", '\n') as line
 where line ilike '%card%';
