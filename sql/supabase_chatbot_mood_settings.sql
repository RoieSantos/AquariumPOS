-- Customer mood settings for GMA Conversations' mood emoji - per "where is the setup settings".
-- Saved from the "Customer mood (Conversations)" section on docs/ai-bot-setup.html (super users),
-- read by facebook-messenger-webhook's mood.ts on every customer message.
--
--   MoodEnabled       - off = no mood checks at all (no AI cost); moods already shown stay as they are.
--   MoodModel         - claude-haiku-5-5 (cheap, default) or claude-sonnet-5-5 (more nuance, ~20x cost).
--                       Wins over the MOOD_MODEL Edge Function secret.
--   MoodDelaySeconds  - how long after the customer's last message to wait before reading the mood,
--                       so a burst of messages costs one check (10-120, default 30).
--
-- Independent of the mood columns file (supabase_gma_conversation_mood.sql) - either order works.
-- Safe to re-run (never overwrites values already saved on AI Bot Setup).

alter table public."ChatbotAiSettings" add column if not exists "MoodEnabled" boolean not null default true;
alter table public."ChatbotAiSettings" add column if not exists "MoodModel" varchar(60) not null default 'claude-haiku-5-5';
alter table public."ChatbotAiSettings" add column if not exists "MoodDelaySeconds" int not null default 30;

comment on column public."ChatbotAiSettings"."MoodEnabled" is 'Customer mood check in the Messenger webhook (mood.ts) on/off. Set on docs/ai-bot-setup.html.';
comment on column public."ChatbotAiSettings"."MoodModel" is 'Model for the customer mood check: claude-haiku-5-5 or claude-sonnet-5-5.';
comment on column public."ChatbotAiSettings"."MoodDelaySeconds" is 'Seconds after the customer''s last message before reading the mood (10-120).';

create or replace function public.admin_set_chatbot_mood_settings(
  p_admin_username text,
  p_admin_password text,
  p_enabled boolean,
  p_model text,
  p_delay_seconds int
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if coalesce(p_model, '') not in ('claude-haiku-5-5', 'claude-sonnet-5-5') then
    raise exception 'Pick Haiku 5.5 or Sonnet 5.5.';
  end if;
  if p_delay_seconds is null or p_delay_seconds < 10 or p_delay_seconds > 120 then
    raise exception 'Wait time must be between 10 and 120 seconds.';
  end if;

  update public."ChatbotAiSettings"
     set "MoodEnabled" = coalesce(p_enabled, false),
         "MoodModel" = p_model,
         "MoodDelaySeconds" = p_delay_seconds
   where "Id" = 1;
  if not found then
    raise exception 'AI settings row not found.';
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_mood_settings(text, text, boolean, text, int) to anon;

notify pgrst, 'reload schema';
