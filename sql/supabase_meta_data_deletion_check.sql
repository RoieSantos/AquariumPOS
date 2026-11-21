-- READ-ONLY check for a Meta "User Data Deletion Request" (app RSPetStopMessenger).
-- IDs redacted after the run (kept out of git - this is a deletion request). To reuse, replace <META_ID_n> with the IDs from Meta's file.
-- Lists every table/column holding one of the requested Facebook IDs and how many rows match.
-- IDs from Meta's "Download User Identifiers" file 2026-11-20.csv.
-- Safe to re-run. Ends in ONE result query (Supabase SQL editor shows only the last result).

with ids(id) as (values ('<META_ID_1>'), ('<META_ID_2>'))
select 'AdvanceOrders.CustomerPsid' as section, i.id, count(t.*) as rows from ids i left join public."AdvanceOrders" t on t."CustomerPsid" = i.id group by i.id
union all select 'AutomatedOrders.Psid', i.id, count(t.*) from ids i left join public."AutomatedOrders" t on t."Psid" = i.id group by i.id
union all select 'AutomatedOrders.GmaPsid', i.id, count(t.*) from ids i left join public."AutomatedOrders" t on t."GmaPsid" = i.id group by i.id
union all select 'OnlineOrders.WalkinPsid', i.id, count(t.*) from ids i left join public."OnlineOrders" t on t."WalkinPsid" = i.id group by i.id
union all select 'OnlineCustomers.FbID', i.id, count(t.*) from ids i left join public."OnlineCustomers" t on t."FbID"::text = i.id group by i.id
union all select 'ChatbotAdReferrals.Psid', i.id, count(t.*) from ids i left join public."ChatbotAdReferrals" t on t."Psid" = i.id group by i.id
union all select 'ChatbotCalls.Psid', i.id, count(t.*) from ids i left join public."ChatbotCalls" t on t."Psid" = i.id group by i.id
union all select 'ChatbotConversationReads.Psid', i.id, count(t.*) from ids i left join public."ChatbotConversationReads" t on t."Psid" = i.id group by i.id
union all select 'ChatbotConversationTags.Psid', i.id, count(t.*) from ids i left join public."ChatbotConversationTags" t on t."Psid" = i.id group by i.id
union all select 'ChatbotConversations.Psid', i.id, count(t.*) from ids i left join public."ChatbotConversations" t on t."Psid" = i.id group by i.id
union all select 'ChatbotCustomerContacts.Psid', i.id, count(t.*) from ids i left join public."ChatbotCustomerContacts" t on t."Psid" = i.id group by i.id
union all select 'ChatbotFollowUps.Psid', i.id, count(t.*) from ids i left join public."ChatbotFollowUps" t on t."Psid" = i.id group by i.id
union all select 'ChatbotLocationRequests.Psid', i.id, count(t.*) from ids i left join public."ChatbotLocationRequests" t on t."Psid" = i.id group by i.id
union all select 'ChatbotMessages.Psid', i.id, count(t.*) from ids i left join public."ChatbotMessages" t on t."Psid" = i.id group by i.id
union all select 'ChatbotToolCalls.Psid', i.id, count(t.*) from ids i left join public."ChatbotToolCalls" t on t."Psid" = i.id group by i.id
union all select 'FacebookPostComments.Psid', i.id, count(t.*) from ids i left join public."FacebookPostComments" t on t."Psid" = i.id group by i.id
union all select 'OrderNowSessionTokens.Psid', i.id, count(t.*) from ids i left join public."OrderNowSessionTokens" t on t."Psid" = i.id group by i.id
union all select 'ReceiptAcknowledgements.Psid', i.id, count(t.*) from ids i left join public."ReceiptAcknowledgements" t on t."Psid" = i.id group by i.id
order by 3 desc, 1, 2;
