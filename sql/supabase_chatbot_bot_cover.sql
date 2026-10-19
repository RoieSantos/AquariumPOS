-- Messenger bot ("Vic") emergency cover - per "if there is an emergency and no staff is present i
-- want to enable the bot to answer". Overrides the schedule hours (supabase_chatbot_bot_schedule.sql)
-- until BotCoverUntilUtc: while it's in the future the bot answers Messenger even off-schedule, then
-- the normal schedule takes over again by itself - nobody has to remember to switch it back.
--
-- Started/stopped from the "Emergency cover" box on docs/ai-bot-setup.html (super users).
-- Read by supabase/functions/_shared/bot-schedule.ts (webhook + follow-up dispatcher).
-- Run AFTER supabase_chatbot_bot_schedule.sql. Safe to re-run.

alter table public."ChatbotAiSettings" add column if not exists "BotCoverUntilUtc" timestamptz;

comment on column public."ChatbotAiSettings"."BotCoverUntilUtc" is 'Emergency cover: while in the future, the Messenger bot answers even outside BotSchedule. Null/past = normal schedule. Set on docs/ai-bot-setup.html.';

-- p_hours = how long to cover from now (max 72). Null or 0 = stop cover now.
create or replace function public.admin_set_chatbot_bot_cover(
  p_admin_username text,
  p_admin_password text,
  p_hours numeric
)
returns timestamptz
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_until timestamptz;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_hours is not null and (p_hours < 0 or p_hours > 72) then
    raise exception 'Cover must be between 0 and 72 hours.';
  end if;

  v_until := case when coalesce(p_hours, 0) = 0 then null else now() + make_interval(secs => p_hours * 3600) end;

  update public."ChatbotAiSettings"
     set "BotCoverUntilUtc" = v_until
   where "Id" = 1;
  if not found then
    raise exception 'AI settings row not found.';
  end if;

  return v_until;
end;
$$;

grant execute on function public.admin_set_chatbot_bot_cover(text, text, numeric) to anon;
