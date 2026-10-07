-- Read-only check: why order 110119's To-Ship Message dialog says "Not authorized." for a Store
-- Manager / Production Manager. admin_send_chatbot_message lets them send only if:
--   1. the live admin_send_chatbot_message calls is_online_order_messenger_authorized
--      (supabase_online_order_gma_message_managers.sql actually ran and wasn't overwritten),
--   2. the order's GmaPsid is on an AutomatedOrders row with PancakeReceiptNo = the order no,
--   3. the staff user is active and flagged Store Manager / has the ProductionManager role.
--
-- Safe to run any time. ONE result.

select '1 live send function' as section,
       p.oid::regprocedure::text as item,
       case when p.prosrc ilike '%is_online_order_messenger_authorized%'
            then 'OK - manager/staff check present'
            else 'PROBLEM - old version (Super User / Conversations Access only)' end as detail
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'admin_send_chatbot_message'

union all
select '2 helper function',
       coalesce(max(p.oid::regprocedure::text), 'is_online_order_messenger_authorized'),
       case when count(*) = 0 then 'PROBLEM - missing (managers file never ran)'
            when bool_or(p.prosrc ilike '%is_staff_authorized%') then 'OK - any active staff version'
            else 'OK - Store Manager / Production Manager version' end
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'is_online_order_messenger_authorized'

union all
select '3 order 110119 AutomatedOrders',
       coalesce(ao."OrderNo"::text, '?') ,
       'GmaPsid=' || coalesce(ao."GmaPsid", 'NULL') || ' | PancakeReceiptNo=' || coalesce(ao."PancakeReceiptNo", 'NULL')
from public."AutomatedOrders" ao
where ao."PancakeReceiptNo" = '110119' or ao."GmaPsid" in (
  select a2."GmaPsid" from public."AutomatedOrders" a2 where a2."PancakeReceiptNo" = '110119')

union all
select '3 order 110119 AutomatedOrders', 'none',
       'PROBLEM - no AutomatedOrders row has PancakeReceiptNo 110119'
where not exists (select 1 from public."AutomatedOrders" where "PancakeReceiptNo" = '110119')

union all
select '4 conversation for that psid', c."Psid",
       coalesce(c."CustomerName", '') || ' | paused=' || c."IsPaused"::text
from public."ChatbotConversations" c
where c."Psid" in (select "GmaPsid" from public."AutomatedOrders" where "PancakeReceiptNo" = '110119')

union all
select '5 manager staff users', s."Username",
       'active=' || coalesce(s."IsActive"::text, 'NULL') || ' | StoreManager=' || coalesce(s."StoreManager"::text, 'NULL')
       || ' | roles=' || coalesce(s."StaffRoles"::text, 'NULL')
from public."StaffUsers" s
where coalesce(s."StoreManager", false) or s."StaffRoles"::text ilike '%ProductionManager%'

order by 1, 2;
