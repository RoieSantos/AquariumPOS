-- READ-ONLY: is anyone using the portal chat bubble (chat.js) to talk to each other?
-- Safe to re-run any time. Changes nothing.
--
-- One result set:
--   section = '1 summary'      -> totals across all chats (staff-to-staff vs. chats that include Alice)
--   section = '2 conversation' -> one row per conversation: who's in it, message count, who sent how many,
--                                 first/last message time (Manila time), messages in the last 7 days
-- Message text is NOT shown here; only counts.

with conv as (
  select
    c."ConversationID",
    c."IsGroup",
    c."Name",
    c."CreatedBy",
    (select string_agg(m."Username", ', ' order by m."Username")
       from public."ChatConversationMembers" m
      where m."ConversationID" = c."ConversationID") as members,
    exists (select 1 from public."ChatConversationMembers" m
             where m."ConversationID" = c."ConversationID" and m."Username" = 'alice') as has_alice
  from public."ChatConversations" c
),
msg as (
  select
    cm."ConversationID",
    count(*)                                                               as messages,
    count(*) filter (where cm."SenderUsername" <> 'alice')                 as staff_messages,
    count(*) filter (where cm."CreatedAtUtc" >= now() - interval '7 days') as last_7_days,
    min(cm."CreatedAtUtc")                                                 as first_at,
    max(cm."CreatedAtUtc")                                                 as last_at
  from public."ChatMessages" cm
  group by cm."ConversationID"
),
senders as (
  select s."ConversationID",
         string_agg(s."SenderUsername" || ' (' || s.n || ')', ', ' order by s.n desc) as sent_by
  from (select "ConversationID", "SenderUsername", count(*) as n
          from public."ChatMessages" group by 1, 2) s
  group by s."ConversationID"
)
select
  '1 summary'                                                         as section,
  'ALL CHATS'                                                         as conversation,
  null::text                                                          as members,
  count(distinct conv."ConversationID")::text || ' conversations, '
    || count(distinct conv."ConversationID") filter (where not conv.has_alice and coalesce(msg.staff_messages,0) > 0)::text
    || ' staff-only with messages'                                    as sent_by,
  coalesce(sum(msg.messages), 0)                                      as messages,
  coalesce(sum(msg.staff_messages) filter (where not conv.has_alice), 0) as staff_to_staff_messages,
  coalesce(sum(msg.last_7_days), 0)                                   as last_7_days,
  to_char(min(msg.first_at) at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI') as first_message_ph,
  to_char(max(msg.last_at)  at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI') as last_message_ph
from conv
left join msg on msg."ConversationID" = conv."ConversationID"

union all

select
  '2 conversation',
  case when conv."IsGroup" then 'Group: ' || coalesce(conv."Name", '(no name)') else 'DM' end
    || case when conv.has_alice then ' [with Alice]' else '' end,
  conv.members,
  coalesce(senders.sent_by, '(no messages)'),
  coalesce(msg.messages, 0),
  case when conv.has_alice then 0 else coalesce(msg.staff_messages, 0) end,
  coalesce(msg.last_7_days, 0),
  to_char(msg.first_at at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'),
  to_char(msg.last_at  at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI')
from conv
left join msg     on msg."ConversationID" = conv."ConversationID"
left join senders on senders."ConversationID" = conv."ConversationID"

order by section, last_message_ph desc nulls last;
