-- READ-ONLY check: are staff replies from GMA Conversations actually reaching Facebook?
-- Safe to re-run. Changes nothing.
--
-- chatbot-staff-reply logs each staff send in ChatbotMessages (SentByUsername set), then stamps
-- DeliveryStatus 'Sent' / 'Failed' after the Facebook Send API attempt. A NULL status on an older
-- row means the function never finished the send (crashed / timed out).
--
-- Sections:
--   1 daily   - per day (last 7 days, Manila time): sent / failed / stuck counts for staff replies
--   2 recent  - the 20 most recent staff replies with their status
--   3 bot     - same daily counts for bot (Vic) replies, for comparison

with staff as (
  select m."Id", m."Psid", m."SentByUsername", m."DeliveryStatus", m."Content", m."CreatedAtUtc"
  from public."ChatbotMessages" m
  where m."SentByUsername" is not null
    and m."Role" <> 'user'
    and m."CreatedAtUtc" >= now() - interval '7 days'
),
bot as (
  select m."DeliveryStatus", m."CreatedAtUtc"
  from public."ChatbotMessages" m
  where m."SentByUsername" is null
    and m."Role" = 'assistant'
    and m."CreatedAtUtc" >= now() - interval '7 days'
)
select * from (
  select '1 daily' as section,
         to_char(("CreatedAtUtc" at time zone 'Asia/Manila')::date, 'YYYY-MM-DD') as when_ph,
         null::text as psid,
         null::text as sent_by,
         count(*) filter (where "DeliveryStatus" = 'Sent')   || ' sent / ' ||
         count(*) filter (where "DeliveryStatus" = 'Failed') || ' failed / ' ||
         count(*) filter (where "DeliveryStatus" is null and "CreatedAtUtc" < now() - interval '2 minutes') || ' stuck' as status,
         null::text as content
  from staff
  group by 2

  union all

  select * from (
    select '2 recent',
           to_char("CreatedAtUtc" at time zone 'Asia/Manila', 'YYYY-MM-DD HH24:MI'),
           "Psid",
           "SentByUsername",
           coalesce("DeliveryStatus", 'NULL (never finished)'),
           left(coalesce(nullif("Content", ''), '[attachment]'), 80)
    from staff
    order by "CreatedAtUtc" desc
    limit 20
  ) r

  union all

  select '3 bot',
         to_char(("CreatedAtUtc" at time zone 'Asia/Manila')::date, 'YYYY-MM-DD'),
         null, null,
         count(*) filter (where "DeliveryStatus" = 'Sent')   || ' sent / ' ||
         count(*) filter (where "DeliveryStatus" = 'Failed') || ' failed',
         null
  from bot
  group by 2
) x
order by section, when_ph desc;
