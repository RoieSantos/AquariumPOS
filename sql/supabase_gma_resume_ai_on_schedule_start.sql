-- GMA Conversations: when Vic's schedule hours START, the AI comes back on in every Messenger chat
-- that a staff reply paused - per "can we put back the switch to become resume ai when vic start its
-- schedule?". Before this, a staff pause only ended on its own auto-resume timer, so a chat paused
-- during the day (or an old pause with no timer at all) stayed silent through the night shift.
--
--   * cron_gma_auto_resume_bot (every minute) now remembers whether the bot was in schedule on the
--     last tick (ChatbotAiSettings."BotScheduleWasOn"). On the off -> on tick it sets
--     AutoResumeAtUtc = now() on every paused, non-manual Messenger conversation, so the existing
--     auto-resume step in the same tick un-pauses them and answers any customer left waiting
--     (within Messenger's 24h window) - see handleAutoResume in facebook-messenger-webhook.
--   * Manual "Pause AI" (Super User, PausedManually) is left alone - it stays paused until Resume AI.
--   * Website (Alice) chats are left alone - the schedule doesn't apply to her.
--   * Emergency cover starting (BotCoverUntilUtc) counts as the bot coming on, same as schedule start.
--   * Schedule turned off on AI Bot Setup = bot always on = no "start" moment; nothing changes.
--
-- _chatbot_bot_in_schedule is a SQL copy of isWithinBotSchedule
-- (supabase/functions/_shared/bot-schedule.ts) - keep the two in step.
--
-- Run AFTER supabase_gma_bot_auto_resume.sql, supabase_chatbot_bot_schedule.sql and
-- supabase_chatbot_bot_cover.sql. Re-creates cron_gma_auto_resume_bot (the version in
-- supabase_gma_bot_auto_resume.sql + the schedule-start step) - if that file is ever re-run, run this
-- one again afterwards. Safe to re-run. No Edge Function redeploy needed.

alter table public."ChatbotAiSettings" add column if not exists "BotScheduleWasOn" boolean;

comment on column public."ChatbotAiSettings"."BotScheduleWasOn" is 'Bot in schedule on the last cron_gma_auto_resume_bot tick - used to spot the moment hours start and resume staff-paused chats.';

-- ---------------------------------------------------------------------------
-- Same rules as isWithinBotSchedule (bot-schedule.ts), Asia/Manila time.

create or replace function public._chatbot_bot_in_schedule(p_now timestamptz default now())
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s record;
  v_local timestamp := p_now at time zone 'Asia/Manila';
  v_day int := extract(dow from v_local)::int;          -- 0 = Sunday
  v_min int := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  v_today jsonb;
  v_yday jsonb;
  t_start int; t_end int; y_start int; y_end int;
begin
  select "BotScheduleEnabled", "BotSchedule", "BotCoverUntilUtc" into s
  from public."ChatbotAiSettings" where "Id" = 1;

  if not found or s."BotScheduleEnabled" is distinct from true then return true; end if;
  if s."BotCoverUntilUtc" is not null and s."BotCoverUntilUtc" > p_now then return true; end if;
  if s."BotSchedule" is null or jsonb_typeof(s."BotSchedule") <> 'array' or jsonb_array_length(s."BotSchedule") <> 7 then
    return true;
  end if;

  v_today := s."BotSchedule" -> v_day;
  v_yday := s."BotSchedule" -> ((v_day + 6) % 7);

  if coalesce((v_today->>'on')::boolean, false)
     and coalesce(v_today->>'start', '') ~ '^\d{1,2}:\d{2}$' and coalesce(v_today->>'end', '') ~ '^\d{1,2}:\d{2}$' then
    t_start := split_part(v_today->>'start', ':', 1)::int * 60 + split_part(v_today->>'start', ':', 2)::int;
    t_end := split_part(v_today->>'end', ':', 1)::int * 60 + split_part(v_today->>'end', ':', 2)::int;
    if (t_end > t_start and v_min >= t_start and v_min < t_end) or (t_end <= t_start and v_min >= t_start) then
      return true;
    end if;
  end if;

  if coalesce((v_yday->>'on')::boolean, false)
     and coalesce(v_yday->>'start', '') ~ '^\d{1,2}:\d{2}$' and coalesce(v_yday->>'end', '') ~ '^\d{1,2}:\d{2}$' then
    y_start := split_part(v_yday->>'start', ':', 1)::int * 60 + split_part(v_yday->>'start', ':', 2)::int;
    y_end := split_part(v_yday->>'end', ':', 1)::int * 60 + split_part(v_yday->>'end', ':', 2)::int;
    if y_end <= y_start and v_min < y_end then
      return true;
    end if;
  end if;

  return false;
end;
$$;

revoke execute on function public._chatbot_bot_in_schedule(timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Every minute: (new) schedule-start step, then the auto-resume wake-up as before.

create or replace function public.cron_gma_auto_resume_bot()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_anon_key text := 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz';
  v_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/facebook-messenger-webhook?task=auto-resume';
  v_in_schedule boolean := public._chatbot_bot_in_schedule(now());
  v_was_on boolean;
begin
  -- Schedule start: hand every staff-paused Messenger chat an already-expired timer, so the
  -- auto-resume step below switches the AI back on and answers anyone left waiting.
  select "BotScheduleWasOn" into v_was_on from public."ChatbotAiSettings" where "Id" = 1;
  if v_in_schedule and v_was_on is not null and not v_was_on then
    update public."ChatbotConversations"
    set "AutoResumeAtUtc" = now()
    where "IsPaused"
      and not coalesce("PausedManually", false)
      and coalesce("PageId", '') <> 'website';
  end if;
  if v_was_on is distinct from v_in_schedule then
    update public."ChatbotAiSettings" set "BotScheduleWasOn" = v_in_schedule where "Id" = 1;
  end if;

  if not exists (
    select 1 from public."ChatbotConversations"
    where "IsPaused" and "AutoResumeAtUtc" is not null and "AutoResumeAtUtc" <= now()
  ) then
    return;
  end if;

  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '10000');
    perform extensions.http((
      'POST',
      v_url,
      array[
        extensions.http_header('Authorization', 'Bearer ' || v_anon_key),
        extensions.http_header('apikey', v_anon_key)
      ],
      'application/json',
      '{}'
    )::extensions.http_request);
  exception when others then
    null; -- best-effort; the next tick a minute from now retries
  end;
end;
$$;

revoke execute on function public.cron_gma_auto_resume_bot() from public, anon, authenticated;

-- Last statement = one result: is the bot in schedule right now, and how many chats the next
-- schedule start would switch back on.
select
  public._chatbot_bot_in_schedule(now()) as bot_in_schedule_now,
  (select count(*) from public."ChatbotConversations"
    where "IsPaused" and not coalesce("PausedManually", false) and coalesce("PageId", '') <> 'website') as staff_paused_messenger_chats,
  (select count(*) from public."ChatbotConversations"
    where "IsPaused" and coalesce("PausedManually", false)) as manual_pauses_left_alone;
