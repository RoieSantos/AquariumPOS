-- Meta "User Data Deletion Request" for app RSPetStopMessenger - IDs file 2026-11-20.csv.
-- IDs redacted after the run (kept out of git - this is a deletion request). To reuse, replace <META_ID_n> with the IDs from Meta's file.
-- Run AFTER checking with supabase_meta_data_deletion_check.sql.
--
-- Of the 2 IDs, only one PSID exists in our DB (one Messenger conversation from
-- 2026-10-07: 3 messages, 1 read marker, 1 skipped follow-up; no orders, contacts or customers).
-- The other ID is not in our DB - per Meta's notice it can be disregarded.
--
-- Deletes every row tied to the PSID. ChatbotMessages / ChatbotFollowUps / ChatbotLocationRequests
-- cascade from ChatbotConversations, but are listed explicitly so this file covers any table
-- even if the FK changes. Safe to re-run (deletes nothing the second time).
-- Ends with ONE result query showing what remains (should be all zeros).

begin;

delete from public."ChatbotMessages"          where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ChatbotFollowUps"         where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ChatbotLocationRequests"  where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ChatbotConversationReads" where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ChatbotConversationTags"  where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ChatbotCustomerContacts"  where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ChatbotToolCalls"         where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ChatbotAdReferrals"       where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ChatbotCalls"             where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."FacebookPostComments"     where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ReceiptAcknowledgements"  where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."OrderNowSessionTokens"    where "Psid" in ('<META_ID_2>', '<META_ID_1>');
delete from public."ChatbotConversations"     where "Psid" in ('<META_ID_2>', '<META_ID_1>');

commit;

select 'ChatbotConversations' as section, count(*) as remaining from public."ChatbotConversations" where "Psid" in ('<META_ID_2>', '<META_ID_1>')
union all select 'ChatbotMessages', count(*) from public."ChatbotMessages" where "Psid" in ('<META_ID_2>', '<META_ID_1>')
union all select 'ChatbotFollowUps', count(*) from public."ChatbotFollowUps" where "Psid" in ('<META_ID_2>', '<META_ID_1>')
union all select 'ChatbotConversationReads', count(*) from public."ChatbotConversationReads" where "Psid" in ('<META_ID_2>', '<META_ID_1>');
