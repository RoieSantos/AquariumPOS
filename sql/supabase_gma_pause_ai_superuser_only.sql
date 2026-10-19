-- GMA Conversations: Pause AI / Resume AI is Super User only - per "can we also disable the resume ai
-- and pause ai button, only super user can do this". Same body as the live definition in
-- supabase_gma_bot_auto_resume.sql (hand pause has no timer; resume clears it all); only the auth
-- check changes from is_conversations_authorized to is_admin_authorized (Super Users).
-- Staff replies still auto-pause the bot and the auto-resume timer still runs - those don't go
-- through this function. The button is greyed out for non-Super Users in gmaConversations.js.
--
-- Run AFTER supabase_gma_bot_auto_resume.sql and supabase_gma_conversations_staff_rpc_access.sql -
-- re-running either of those afterwards would let all Conversations staff pause/resume again.
-- Safe to re-run.

create or replace function public.admin_set_chatbot_conversation_paused(
  p_admin_username text,
  p_admin_password text,
  p_psid text,
  p_is_paused boolean
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Only a Super User can pause or resume the AI.';
  end if;
  if p_psid is null or trim(p_psid) = '' then
    raise exception 'Psid is required.';
  end if;

  update public."ChatbotConversations"
  set "IsPaused" = coalesce(p_is_paused, false),
      "PausedManually" = coalesce(p_is_paused, false),
      "AutoResumeAtUtc" = null
  where "Psid" = p_psid;

  if not found then
    raise exception 'No conversation found for that Psid.';
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_conversation_paused(text, text, text, boolean) to anon;
