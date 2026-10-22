-- Receipt acknowledgements - per "can we teach the aibot to backread and see whether the customer is happy
-- with the receipt and point that the order in the receipt is what they confirmed and received?"
--
-- facebook-messenger-webhook logs the customer's first few replies (up to 5) after ANY message carrying a
-- receipt link (online-order-receipt.html?order=...), whether staff or the bot sent it - e.g. staff send
-- "Your order has been confirmed, please see receipt... #HFK <link>" and the customer answers 👍 then
-- "Nope, I think everything is cleared to your end". A 👍 Like is stored as "[👍 Like]".
-- The bot's get_order_status returns the latest row for the order as acceptance.receiptAcknowledgement, so a
-- "that's not what I ordered" complaint days later can point to it even after the exchange has scrolled out
-- of the bot's 20-message history. Raw replies only - the bot judges acknowledgement vs correction.
--
-- Service role only (webhook + bot) - no anon/authenticated access. Safe to re-run.

create table if not exists public."ReceiptAcknowledgements" (
  "OrderRef"         text        not null,  -- the ?order= value: AO-xxxxx or an Online Order ID
  "Psid"             text        not null,
  "ReceiptSentAtUtc" timestamptz not null,  -- when the message with the receipt link was sent
  "SentByRole"       text,                  -- 'staff' or 'assistant' (the bot)
  "Replies"          text,                  -- customer's replies after it, one per line
  "ReplyCount"       int         not null default 0,
  "FirstReplyAtUtc"  timestamptz,
  "LastReplyAtUtc"   timestamptz,
  primary key ("OrderRef", "Psid")
);

alter table public."ReceiptAcknowledgements" enable row level security;
revoke all on public."ReceiptAcknowledgements" from anon, authenticated;

comment on table public."ReceiptAcknowledgements" is 'Customer replies right after a receipt link was sent in Messenger (facebook-messenger-webhook). Read by the AI bot get_order_status for "not what I ordered" complaints.';

select 'ReceiptAcknowledgements ready' as result, count(*) as rows from public."ReceiptAcknowledgements";
