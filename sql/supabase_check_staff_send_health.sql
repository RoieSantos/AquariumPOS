-- Read-only check: are staff replies in GMA Conversations going out? Shows quoted (↩) replies per day,
-- each staff user's sends in the last 3 hours, every failed send in the last 48 hours with how long
-- the customer had been quiet (over 24 = Facebook's reply window), and the bot's messages per hour.
-- No message text is shown.
--
-- Safe to run any time. ONE result.

select * from (
select '0 now PH' as section, '' as item, to_char(now() at time zone 'Asia/Manila', 'MM-DD HH24:MI') as detail

union all
select '1 quoted replies by day', to_char(m."CreatedAtUtc" at time zone 'Asia/Manila', 'MM-DD'),
       'quoted=' || count(*) || ' last=' || to_char(max(m."CreatedAtUtc") at time zone 'Asia/Manila', 'HH24:MI')
from public."ChatbotMessages" m
where m."Role" = 'staff' and m."ReplyToMid" is not null and m."CreatedAtUtc" > now() - interval '7 days'
group by 2

union all
select '2 staff sends last 3h', coalesce(m."SentByUsername", 'NULL'),
       'sent=' || count(*) filter (where m."DeliveryStatus" = 'Sent') || ' failed=' || count(*) filter (where m."DeliveryStatus" = 'Failed')
       || ' stuck=' || count(*) filter (where m."DeliveryStatus" is null)
       || ' last=' || to_char(max(m."CreatedAtUtc") at time zone 'Asia/Manila', 'HH24:MI')
from public."ChatbotMessages" m
where m."Role" = 'staff' and m."CreatedAtUtc" > now() - interval '3 hours'
group by 2

union all
select '3 failed staff sends 48h', to_char(m."CreatedAtUtc" at time zone 'Asia/Manila', 'MM-DD HH24:MI') || ' #' || m."Id",
       'by=' || coalesce(m."SentByUsername", 'NULL') || ' attachment=' || coalesce(m."AttachmentType", 'none')
       || ' len=' || length(coalesce(m."Content", ''))
       || ' customer_quiet_hours=' || coalesce(round(extract(epoch from (m."CreatedAtUtc" - (
            select max(u."CreatedAtUtc") from public."ChatbotMessages" u
            where u."Psid" = m."Psid" and u."Role" = 'user' and u."CreatedAtUtc" < m."CreatedAtUtc"))) / 3600)::text, 'none')
from public."ChatbotMessages" m
where m."Role" = 'staff' and m."DeliveryStatus" = 'Failed' and m."CreatedAtUtc" > now() - interval '48 hours'

union all
select '4 bot msgs by hour', to_char(m."CreatedAtUtc" at time zone 'Asia/Manila', 'MM-DD HH24:00'),
       coalesce(m."DeliveryStatus", 'NULL') || ' count=' || count(*)
from public."ChatbotMessages" m
where m."Role" = 'assistant' and m."CreatedAtUtc" > now() - interval '30 hours'
group by 2, m."DeliveryStatus"
) x
order by section, item desc;
