-- GMA Conversations: Messenger calls to the Page (notify only - see
-- supabase/functions/facebook-messenger-webhook/calls.ts). Staff still answer in Meta Business
-- Suite / the Facebook app; this only records each call so GMA Conversations can show a live
-- "📞 ... is calling" banner and a "📞 Voice call · 2 min" / "📞 Missed call" line in the thread
-- (that line itself is a normal ChatbotMessages row the webhook writes).
--
--   ChatbotCalls                    - one row per call: who (Psid), which Page, when it started/ended,
--                                     duration, Answered/Missed. Needed because Facebook's 'terminate'
--                                     event carries only the call id, not the caller.
--   admin_list_ringing_chatbot_calls - calls still ringing (started < 2 min ago, not ended) - so a GMA
--                                     tab opened mid-ring still shows the banner.
--
-- Service-role only for writes (the webhook), same as ChatbotMessages. Safe to re-run.

create table if not exists public."ChatbotCalls" (
  "CallId" text primary key,
  "Psid" text not null,
  "PageId" text,
  "Direction" text,
  "StartedAtUtc" timestamptz not null default now(),
  "EndedAtUtc" timestamptz,
  "DurationSeconds" int,
  "Status" text,           -- 'Answered' / 'Missed' (null while ringing)
  "FacebookStatus" text    -- Facebook's own terminate status, as sent
);

create index if not exists "IX_ChatbotCalls_Psid" on public."ChatbotCalls" ("Psid", "StartedAtUtc" desc);

alter table public."ChatbotCalls" enable row level security;
revoke all on public."ChatbotCalls" from anon, authenticated;

drop function if exists public.admin_list_ringing_chatbot_calls(text, text);

create or replace function public.admin_list_ringing_chatbot_calls(
  p_admin_username text,
  p_admin_password text
)
returns table(call_id text, psid text, page_id text, customer_name text, started_at_utc timestamptz)
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
    select k."CallId"::text, k."Psid"::text, k."PageId"::text, c."CustomerName"::text, k."StartedAtUtc"
    from public."ChatbotCalls" k
    left join public."ChatbotConversations" c on c."Psid" = k."Psid"
    where k."EndedAtUtc" is null
      and k."StartedAtUtc" > now() - interval '2 minutes'
    order by k."StartedAtUtc" desc;
end;
$$;

grant execute on function public.admin_list_ringing_chatbot_calls(text, text) to anon;

notify pgrst, 'reload schema';
