-- Messenger bot ("Vic") schedule hours - per "can we put a schedule hours?" on the always-on bot.
-- When BotScheduleEnabled is on, facebook-messenger-webhook only auto-replies inside the weekly
-- BotSchedule window (Asia/Manila time). Outside it, customer messages are still saved and show in
-- Conversations - the bot just stays silent so staff answer. Due follow-ups wait until hours start,
-- and an auto-resume that expires off-hours turns the bot back on without replying.
--
--   BotSchedule = JSON array of 7 days, index 0 = Sunday ... 6 = Saturday:
--     [{"on": true, "start": "08:00", "end": "20:00"}, ...]
--   An end at or before the start runs past midnight into the next day (e.g. 20:00 -> 08:00);
--   start = end means the whole 24 hours.
--
-- Toggled/saved on docs/ai-bot-setup.html (super users). Website widget (Alice) is not affected.
-- First run turns it on at 8 PM -> 8 AM daily (night shift, see the end of this file).
-- Safe to re-run.

alter table public."ChatbotAiSettings" add column if not exists "BotScheduleEnabled" boolean not null default false;
alter table public."ChatbotAiSettings" add column if not exists "BotSchedule" jsonb;

comment on column public."ChatbotAiSettings"."BotScheduleEnabled" is 'When true, the Messenger bot only auto-replies inside BotSchedule (Asia/Manila). Off = always on. Set on docs/ai-bot-setup.html.';
comment on column public."ChatbotAiSettings"."BotSchedule" is 'Array of 7 {on, start "HH:MM", end "HH:MM"}, index 0 = Sunday. end <= start wraps past midnight.';

create or replace function public.admin_set_chatbot_bot_schedule(
  p_admin_username text,
  p_admin_password text,
  p_enabled boolean,
  p_schedule jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_day jsonb;
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  if p_schedule is not null then
    if jsonb_typeof(p_schedule) <> 'array' or jsonb_array_length(p_schedule) <> 7 then
      raise exception 'Schedule must list all 7 days.';
    end if;
    for v_day in select * from jsonb_array_elements(p_schedule) loop
      if coalesce((v_day->>'on')::boolean, false)
         and (coalesce(v_day->>'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              or coalesce(v_day->>'end', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$') then
        raise exception 'Each day that is on needs a start and end time.';
      end if;
    end loop;
  end if;

  if coalesce(p_enabled, false) and p_schedule is null then
    raise exception 'Set the schedule before turning it on.';
  end if;

  update public."ChatbotAiSettings"
     set "BotScheduleEnabled" = coalesce(p_enabled, false),
         "BotSchedule" = coalesce(p_schedule, "BotSchedule")
   where "Id" = 1;
  if not found then
    raise exception 'AI settings row not found.';
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_bot_schedule(text, text, boolean, jsonb) to anon;

-- Starting schedule: Vic covers the night shift, 8 PM -> 8 AM every day, when no staff is present;
-- staff answer during the day. Only seeded the first time (BotSchedule still empty), so re-running
-- this file never overwrites hours later changed on AI Bot Setup.
update public."ChatbotAiSettings"
   set "BotScheduleEnabled" = true,
       "BotSchedule" = (select jsonb_agg(jsonb_build_object('on', true, 'start', '20:00', 'end', '08:00')) from generate_series(1, 7))
 where "Id" = 1
   and "BotSchedule" is null;
