-- READ-ONLY: read the messages staff sent each other in the portal chat bubble (chat.js).
-- Safe to re-run any time. Changes nothing.
--
-- One row per message, grouped by conversation, oldest first within each conversation
-- (newest-active conversation at the top). Times are Manila time.
--
-- Optional filters - edit the values in the "params" block below:
--   person_1      -> only conversations this username is in (e.g. 'jen'); null = everyone
--   person_2      -> also set this to see only what person_1 and person_2 said to each other (e.g. 'mark')
--   only_the_two  -> true  = only 1-on-1 chats (exactly 2 members), no group chats.
--                            With no names set, that's EVERY private DM between staff.
--                    false = also group chats
--   skip_alice    -> true (default) hides conversations that include Alice (the AI bot)
--   since_days    -> only messages from the last N days; null = all history
--
-- Don't know the usernames? Run supabase_portal_chat_usage_check.sql first - its "members" column lists them.

with params as (
  select
    null::text as person_1,      -- e.g. 'jen'
    null::text as person_2,      -- e.g. 'mark'
    true       as only_the_two,
    true       as skip_alice,
    null::int  as since_days     -- e.g. 7
),
conv as (
  select
    c."ConversationID",
    case when c."IsGroup" then 'Group: ' || coalesce(c."Name", '(no name)') else 'DM' end as conversation,
    (select string_agg(m."Username", ', ' order by m."Username")
       from public."ChatConversationMembers" m
      where m."ConversationID" = c."ConversationID") as members,
    exists (select 1 from public."ChatConversationMembers" m
             where m."ConversationID" = c."ConversationID" and m."Username" = 'alice') as has_alice,
    (select count(*) from public."ChatConversationMembers" m
      where m."ConversationID" = c."ConversationID") as member_count,
    (select max(cm."CreatedAtUtc") from public."ChatMessages" cm
      where cm."ConversationID" = c."ConversationID") as last_at
  from public."ChatConversations" c
)
select
  conv.conversation || case when conv.has_alice then ' [with Alice]' else '' end as conversation,
  conv.members,
  to_char(cm."CreatedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI') as sent_ph,
  coalesce(su."DisplayName", cm."SenderUsername") || ' (' || cm."SenderUsername" || ')' as sender,
  cm."Body" as message
from public."ChatMessages" cm
join conv on conv."ConversationID" = cm."ConversationID"
left join public."StaffUsers" su on su."Username" = cm."SenderUsername"
cross join params p
where (p.person_1 is null
       or exists (select 1 from public."ChatConversationMembers" m
                   where m."ConversationID" = cm."ConversationID" and m."Username" = p.person_1))
  and (p.person_2 is null
       or exists (select 1 from public."ChatConversationMembers" m
                   where m."ConversationID" = cm."ConversationID" and m."Username" = p.person_2))
  and (not p.only_the_two or conv.member_count = 2)
  and (not p.skip_alice or not conv.has_alice)
  and (p.since_days is null or cm."CreatedAtUtc" >= now() - make_interval(days => p.since_days))
order by conv.last_at desc, cm."ConversationID", cm."CreatedAtUtc";
