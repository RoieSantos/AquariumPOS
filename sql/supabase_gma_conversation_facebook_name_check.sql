-- Read-only check for supabase_gma_conversation_facebook_name.sql: how many GMA Conversations have
-- their real Facebook name stored (FacebookName) vs still missing it, per Page. Re-run after the
-- names_only backfill to see progress. Changes nothing.

select
  coalesce(c."PageId", '(none)')::text as page_id,
  count(*) as conversations,
  count(*) filter (where nullif(trim(coalesce(c."FacebookName", '')), '') is not null) as has_facebook_name,
  count(*) filter (where nullif(trim(coalesce(c."FacebookName", '')), '') is null) as missing_facebook_name,
  count(*) filter (where c."FacebookName" is distinct from c."CustomerName"
                     and nullif(trim(coalesce(c."FacebookName", '')), '') is not null) as name_differs_from_crm
from public."ChatbotConversations" c
group by c."PageId"
order by conversations desc;
