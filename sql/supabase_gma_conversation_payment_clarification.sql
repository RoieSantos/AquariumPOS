-- Per direct follow-up request: once a conversation already has an order (any status), the bot
-- used to silently assume a NEW payment screenshot belonged to that same order (or, before that,
-- silently refused to create a second one at all). Real customers do come back to buy something
-- else in the same Messenger thread, so instead of guessing, the bot (supabase/functions/facebook-
-- messenger-webhook/index.ts) now ASKS: "is this payment for your existing order, or a new one?" -
-- and waits for the customer's answer before doing anything with the payment.
--
-- These columns on ChatbotConversations remember that question is pending, and the payment details
-- it was about (the detected amount/method/reference - not re-derived from a screenshot the
-- customer already sent), until answered:
--   PendingPaymentClarificationOrderNo         - the existing order this question is about. Null
--                                                 means no clarification is currently pending.
--   PendingPaymentClarificationAmount/Method/Reference - snapshot of DetectedPayment for the
--                                                 screenshot that triggered the question, so the
--                                                 reply handler doesn't need to re-guess which
--                                                 message it was.
--   PendingPaymentClarificationRequestedAtUtc  - when asked. Paired with a "this must be the very
--                                                 FIRST customer reply since then" check (same
--                                                 staleness-guard pattern as ReceiptConfirmation
--                                                 RequestedAtUtc/ReceiptConfirmedAtUtc on
--                                                 AutomatedOrders, sql/supabase_gma_conversation_
--                                                 receipt_confirmation.sql) so an unrelated later
--                                                 reply doesn't wrongly get treated as the answer.
--
-- If the customer answers "existing", the payment is treated as belonging to
-- PendingPaymentClarificationOrderNo (the normal receipt/summary ack runs against that order). If
-- "new", the bot attempts to place a brand new order (create_order, chatbot-engine.ts) using the
-- remembered payment details - this is also what makes multiple orders per conversation possible
-- again, now gated behind an explicit customer answer instead of either a blanket refusal or a
-- silent guess.

alter table public."ChatbotConversations" add column if not exists "PendingPaymentClarificationOrderNo" text;
alter table public."ChatbotConversations" add column if not exists "PendingPaymentClarificationAmount" numeric(18,2);
alter table public."ChatbotConversations" add column if not exists "PendingPaymentClarificationMethod" varchar(30);
alter table public."ChatbotConversations" add column if not exists "PendingPaymentClarificationReference" varchar(200);
alter table public."ChatbotConversations" add column if not exists "PendingPaymentClarificationRequestedAtUtc" timestamptz;

comment on column public."ChatbotConversations"."PendingPaymentClarificationOrderNo" is 'Set by the AI Bot webhook when a payment screenshot arrives and this conversation already has a prior order - asks the customer whether the payment is for that order or a new one. Null once answered (or if never asked).';
comment on column public."ChatbotConversations"."PendingPaymentClarificationAmount" is 'Snapshot of the pending clarification''s detected payment amount - see PendingPaymentClarificationOrderNo.';
comment on column public."ChatbotConversations"."PendingPaymentClarificationMethod" is 'Snapshot of the pending clarification''s detected payment method - see PendingPaymentClarificationOrderNo.';
comment on column public."ChatbotConversations"."PendingPaymentClarificationReference" is 'Snapshot of the pending clarification''s detected payment reference - see PendingPaymentClarificationOrderNo.';
comment on column public."ChatbotConversations"."PendingPaymentClarificationRequestedAtUtc" is 'When the "existing order or new?" question was asked - paired with a first-reply-since check so a later unrelated message never gets misread as answering it.';
