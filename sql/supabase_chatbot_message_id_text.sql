-- ChatbotMessages."FacebookMessageId" varchar(100) -> text. Messenger message ids are long, and the
-- multi-photo / video sync (facebook-messenger-webhook's recordMessageWithAttachments) stores the 2nd,
-- 3rd... attachment of one message as "<mid>#2", "<mid>#3" - which can go past 100 characters, making
-- those extra rows fail to save ("value too long") and the photos silently go missing.
--
-- varchar -> text is a metadata-only change in Postgres (no table rewrite, instant); the unique
-- redelivery index "UX_ChatbotMessages_FacebookMessageId" keeps working unchanged. Safe to re-run.
-- Ends with one result: the column's type now, and the longest id stored so far.

alter table public."ChatbotMessages" alter column "FacebookMessageId" type text;

select
  (select data_type from information_schema.columns
   where table_schema = 'public' and table_name = 'ChatbotMessages' and column_name = 'FacebookMessageId') as column_type,
  (select max(length("FacebookMessageId")) from public."ChatbotMessages") as longest_id_so_far;
