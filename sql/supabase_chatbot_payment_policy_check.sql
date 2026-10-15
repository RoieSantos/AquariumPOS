-- =====================================================================================
-- READ-ONLY: what the AI bot (Vic / Alice) is told about payment, downpayment and COD.
-- The bot's code has no built-in COD / 50% rule - everything it knows comes from these
-- AI Bot Setup > Store Info fields (ChatbotStoreInfo), fed into buildSystemPrompt.
-- Run the whole file in the Supabase SQL editor. Nothing is changed.
-- =====================================================================================

select 'Payment methods' as section, coalesce("PaymentMethods", '(empty)') as bot_is_told
from public."ChatbotStoreInfo" where "Id" = 1
union all
select 'Delivery policy', coalesce("DeliveryPolicy", '(empty)')
from public."ChatbotStoreInfo" where "Id" = 1
union all
select 'Additional notes', coalesce("AdditionalNotes", '(empty)')
from public."ChatbotStoreInfo" where "Id" = 1;
