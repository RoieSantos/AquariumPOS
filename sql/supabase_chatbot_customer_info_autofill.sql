-- Auto-fill Customers from the conversation - per "if the customer send an information on the
-- conversations can we auto fill in to the customers?".
--
-- The bot already saves name / contact no. / address with its save_customer_info tool, but only
-- while IT is replying - when the bot is paused and staff are chatting, nothing was saved, which
-- left most Customers records blank. Now the webhook's background check after each customer
-- message (facebook-messenger-webhook/mood.ts - the same debounced, cheap-model call as the mood
-- emoji, so no extra AI call) also reads any name / mobile number / address the customer typed and
-- saves it to ChatbotConversations, paused or not:
--   * Contact No. - a PH mobile number (stored as 09xxxxxxxxx) the customer gives as theirs/for
--     their order; replaces the old one when they give a new one.
--   * Address - their delivery/home address; replaces the old one when they give a new one.
--   * Name - only fills a blank or Facebook-profile name; never replaces one the customer typed
--     before or one staff entered on the Customer Card.
-- Only messages since the last check are read, so a value staff corrected isn't put back from an
-- old message.
--
-- This column records when that check last ran (it runs even with Customer mood switched off).
-- Safe to re-run. Then deploy facebook-messenger-webhook.

alter table public."ChatbotConversations" add column if not exists "CustomerInfoCheckedAtUtc" timestamptz;

comment on column public."ChatbotConversations"."CustomerInfoCheckedAtUtc" is 'When the webhook last scanned this chat''s new customer messages for name / contact no. / address to auto-fill the CRM record (facebook-messenger-webhook/mood.ts).';

notify pgrst, 'reload schema';

-- Verification - one result.
select column_name::text, data_type::text
from information_schema.columns
where table_schema = 'public' and table_name = 'ChatbotConversations' and column_name = 'CustomerInfoCheckedAtUtc';
