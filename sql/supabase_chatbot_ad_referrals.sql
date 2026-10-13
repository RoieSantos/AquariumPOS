-- GMA Conversations: show when a customer messaged us from a Facebook ad (Click-to-Messenger).
--
-- Facebook attaches a `referral` (source 'ADS', with ad_id and ads_context_data: ad title, photo /
-- video, post id) to the first message after someone taps the ad's "Send Message" button - or sends it
-- on its own (messaging_referrals webhook field) when they already had a thread with the Page.
-- facebook-messenger-webhook saves each one here:
--   * ChatbotAdReferrals - one row per ad tap: who, which Page, which ad, and the message it came with
--     (Mid -> ChatbotMessages.FacebookMessageId, so the thread can draw the ad above that message).
--   * admin_list_chatbot_ad_referrals - the open thread's ad taps (thread card + header badge).
--   * admin_list_chatbot_conversation_ads - latest ad per conversation for the "📣 Ad" list badge.
--
-- Only taps from now on are known - Facebook's conversation history API doesn't say which old chats
-- came from an ad. Service-role only for writes (the webhook). Safe to re-run.

create table if not exists public."ChatbotAdReferrals" (
  "Id" bigserial primary key,
  "Psid" text not null,
  "PageId" text,
  "Source" text,          -- 'ADS' (others, e.g. 'SHORTLINK', are saved too but not shown as an ad)
  "Type" text,            -- 'OPEN_THREAD'
  "AdId" text,
  "AdTitle" text,
  "PhotoUrl" text,
  "VideoUrl" text,
  "PostId" text,
  "Ref" text,
  "Mid" text,             -- the message it came with (null = a referral event on its own)
  "Raw" jsonb,
  "ReferredAtUtc" timestamptz not null default now()
);

create index if not exists "IX_ChatbotAdReferrals_Psid" on public."ChatbotAdReferrals" ("Psid", "ReferredAtUtc" desc);
create unique index if not exists "UX_ChatbotAdReferrals_Mid" on public."ChatbotAdReferrals" ("Mid") where "Mid" is not null;

alter table public."ChatbotAdReferrals" enable row level security;
revoke all on public."ChatbotAdReferrals" from anon, authenticated;

-- ---------------------------------------------------------------------------
-- The open thread's ad taps.

drop function if exists public.admin_list_chatbot_ad_referrals(text, text, text);

create or replace function public.admin_list_chatbot_ad_referrals(
  p_admin_username text,
  p_admin_password text,
  p_psid text
)
returns table(
  id bigint,
  ad_id text,
  ad_title text,
  photo_url text,
  video_url text,
  post_id text,
  message_id bigint,
  referred_at_utc timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select r."Id", r."AdId", r."AdTitle", r."PhotoUrl", r."VideoUrl", r."PostId",
           (select m."Id"::bigint from public."ChatbotMessages" m
             where r."Mid" is not null and m."FacebookMessageId" = r."Mid" limit 1),
           r."ReferredAtUtc"
    from public."ChatbotAdReferrals" r
    where r."Psid" = p_psid and r."Source" = 'ADS'
    order by r."ReferredAtUtc";
end;
$$;

grant execute on function public.admin_list_chatbot_ad_referrals(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Latest ad per conversation, for the list badge (the ~100 loaded conversations' PSIDs).

drop function if exists public.admin_list_chatbot_conversation_ads(text, text, text[]);

create or replace function public.admin_list_chatbot_conversation_ads(
  p_admin_username text,
  p_admin_password text,
  p_psids text[]
)
returns table(psid text, ad_title text, ad_id text, referred_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select distinct on (r."Psid") r."Psid", r."AdTitle", r."AdId", r."ReferredAtUtc"
    from public."ChatbotAdReferrals" r
    where r."Psid" = any(p_psids) and r."Source" = 'ADS'
    order by r."Psid", r."ReferredAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_chatbot_conversation_ads(text, text, text[]) to anon;

notify pgrst, 'reload schema';
