-- Read-only: are Facebook ad taps (Click-to-Messenger) reaching us? (supabase_chatbot_ad_referrals.sql,
-- facebook-messenger-webhook recordReferral.)
--   total    - ad taps saved, by source (ADS = an ad; others e.g. SHORTLINK = an m.me link).
--   referral - the last 15, newest first. with_message = came with the customer's first message;
--              on_its_own = the messaging_referrals event (tapped the ad in an existing chat).
-- If this errors with 'relation "public.ChatbotAdReferrals" does not exist', run
-- supabase_chatbot_ad_referrals.sql first.

select 'total' as section,
       coalesce(r."Source", '(none)') as item,
       count(*)::text as detail,
       null::text as extra,
       max(r."ReferredAtUtc") as at_utc
from public."ChatbotAdReferrals" r
group by r."Source"
union all
select * from (
  select 'referral',
         coalesce(c."CustomerName", r."Psid"),
         concat_ws(' | ', r."Source", case when r."Mid" is null then 'on_its_own' else 'with_message' end,
                   'Page ' || r."PageId"),
         concat_ws(' | ', 'Ad: ' || coalesce(r."AdTitle", r."AdId"), 'Post ' || r."PostId", 'Ref ' || r."Ref"),
         r."ReferredAtUtc"
  from public."ChatbotAdReferrals" r
  left join public."ChatbotConversations" c on c."Psid" = r."Psid"
  order by r."ReferredAtUtc" desc
  limit 15
) recent;
