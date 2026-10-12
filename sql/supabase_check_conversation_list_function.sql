-- Read-only check: which versions of admin_list_chatbot_conversations exist, and whether the
-- "Mark as unread" pieces from supabase_gma_conversation_mark_unread.sql are in place.
-- Expect one list function row whose args end in "p_read_filter text", MarkedUnreadAtUtc = yes,
-- and admin_mark_chatbot_conversation_unread = yes.

select 'list function' as section,
       pg_get_function_identity_arguments(p.oid) as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_list_chatbot_conversations'

union all
select 'MarkedUnreadAtUtc column',
       case when exists (
         select 1 from information_schema.columns
         where table_schema = 'public' and table_name = 'ChatbotConversations' and column_name = 'MarkedUnreadAtUtc'
       ) then 'yes' else 'NO - run supabase_gma_conversation_mark_unread.sql' end

union all
select 'admin_mark_chatbot_conversation_unread',
       case when exists (
         select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'admin_mark_chatbot_conversation_unread'
       ) then 'yes' else 'NO - run supabase_gma_conversation_mark_unread.sql' end;
