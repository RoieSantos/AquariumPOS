-- GMA Conversations: staff replies pause the AI, and the AI comes back on its own if staff stop
-- answering - per "messages that we send over meta app is not syncing" + "add a timer if the staff
-- did not continue to answer the bot will be activated again".
--
--   * Any NEW staff message (sent from GMA Conversations, or - with the facebook-messenger-webhook
--     update - typed in the Meta app / Business Suite / Page inbox) pauses the AI and starts a timer:
--     ChatbotConversations."AutoResumeAtUtc" = now + ChatbotAiSettings."StaffAutoResumeMinutes"
--     (default 30, 0 = never auto-resume). Every further staff message restarts the timer.
--   * When the timer runs out the AI is active again: the next customer message gets a normal bot
--     reply, and if a customer message is already sitting unanswered, cron_gma_auto_resume_bot (every
--     minute) wakes the webhook to answer it.
--   * "Pause AI" clicked by hand in GMA Conversations stays paused indefinitely ("PausedManually"),
--     staff replies don't put a timer on it; "Resume AI" clears everything.
--
-- Done with an AFTER INSERT trigger on ChatbotMessages, so admin_send_chatbot_message and the webhook
-- don't need re-creating. Re-creates admin_set_chatbot_conversation_paused and
-- admin_list_chatbot_conversations exactly as in supabase_gma_conversations_staff_rpc_access.sql, plus
-- the manual flag / two new columns. Adds admin_get/set_chatbot_auto_resume_minutes.
--
-- Run AFTER supabase_gma_conversations_staff_rpc_access.sql. Safe to re-run. If that file is ever
-- re-run, run this one again afterwards. Then redeploy facebook-messenger-webhook.

alter table public."ChatbotConversations" add column if not exists "AutoResumeAtUtc" timestamptz;
alter table public."ChatbotConversations" add column if not exists "PausedManually" boolean not null default false;
alter table public."ChatbotConversations" add column if not exists "LastStaffMessageAtUtc" timestamptz;
alter table public."ChatbotAiSettings" add column if not exists "StaffAutoResumeMinutes" int not null default 30;

-- ---------------------------------------------------------------------------
-- Staff message -> pause + (re)start the auto-resume timer.

create or replace function public._chatbot_staff_message_autopause()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_minutes int;
begin
  -- Only live staff messages - not old history pulled in by an import/backfill.
  if new."Role" <> 'staff' or coalesce(new."CreatedAtUtc", now()) < now() - interval '10 minutes' then
    return new;
  end if;

  select "StaffAutoResumeMinutes" into v_minutes from public."ChatbotAiSettings" where "Id" = 1;
  v_minutes := coalesce(v_minutes, 30);

  update public."ChatbotConversations"
  set "IsPaused" = true,
      "LastStaffMessageAtUtc" = now(),
      "AutoResumeAtUtc" = case when "PausedManually" or v_minutes <= 0 then null
                               else now() + make_interval(mins => v_minutes) end
  where "Psid" = new."Psid";

  return new;
end;
$$;

revoke execute on function public._chatbot_staff_message_autopause() from public, anon, authenticated;

drop trigger if exists trg_chatbot_staff_message_autopause on public."ChatbotMessages";
create trigger trg_chatbot_staff_message_autopause
  after insert on public."ChatbotMessages"
  for each row execute function public._chatbot_staff_message_autopause();

-- ---------------------------------------------------------------------------
-- Timer length setting (GMA Conversations "AI auto-resume" selector).

create or replace function public.admin_get_chatbot_auto_resume_minutes(p_admin_username text, p_admin_password text)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_minutes int;
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  select "StaffAutoResumeMinutes" into v_minutes from public."ChatbotAiSettings" where "Id" = 1;
  return coalesce(v_minutes, 30);
end;
$$;

grant execute on function public.admin_get_chatbot_auto_resume_minutes(text, text) to anon;

create or replace function public.admin_set_chatbot_auto_resume_minutes(p_admin_username text, p_admin_password text, p_minutes int)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if p_minutes is null or p_minutes < 0 or p_minutes > 1440 then
    raise exception 'Minutes must be between 0 and 1440.';
  end if;
  update public."ChatbotAiSettings" set "StaffAutoResumeMinutes" = p_minutes where "Id" = 1;
  if not found then
    raise exception 'AI settings row not found.';
  end if;
end;
$$;

grant execute on function public.admin_set_chatbot_auto_resume_minutes(text, text, int) to anon;

-- ---------------------------------------------------------------------------
-- Manual Pause AI / Resume AI: a hand pause has no timer; resume clears it all.

drop function if exists public.admin_set_chatbot_conversation_paused(text, text, text, boolean);

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
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
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

-- ---------------------------------------------------------------------------
-- Conversation list + auto_resume_at_utc / paused_manually (for the "AI back at 3:45 PM" label).

drop function if exists public.admin_list_chatbot_conversations(text, text, int, int, text);

create or replace function public.admin_list_chatbot_conversations(
  p_admin_username text,
  p_admin_password text,
  p_page int default 1,
  p_page_size int default 50,
  p_search text default null
)
returns table(
  psid text,
  page_id text,
  customer_name text,
  status text,
  is_paused boolean,
  last_message_at_utc timestamptz,
  last_customer_message_at_utc timestamptz,
  created_at_utc timestamptz,
  last_message_preview text,
  auto_resume_at_utc timestamptz,  -- this file
  paused_manually boolean,         -- this file
  total_count bigint
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_page_size int := least(greatest(coalesce(p_page_size, 50), 1), 200);
  v_page int := greatest(coalesce(p_page, 1), 1);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not public.is_conversations_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select
      c."Psid"::text,
      c."PageId"::text,
      c."CustomerName"::text,
      c."Status"::text,
      c."IsPaused",
      c."LastMessageAtUtc",
      c."LastCustomerMessageAtUtc",
      c."CreatedAtUtc",
      (
        select left(m."Content", 200)
        from public."ChatbotMessages" m
        where m."Psid" = c."Psid"
        order by m."CreatedAtUtc" desc
        limit 1
      )::text,
      c."AutoResumeAtUtc",
      coalesce(c."PausedManually", false),
      count(*) over()
    from public."ChatbotConversations" c
    where
      v_search is null
      or c."CustomerName" ilike '%' || v_search || '%'
      or c."Psid" ilike '%' || v_search || '%'
      or exists (
        select 1 from public."ChatbotMessages" m
        where m."Psid" = c."Psid" and m."Content" ilike '%' || v_search || '%'
      )
    order by coalesce(c."LastMessageAtUtc", c."CreatedAtUtc") desc
    limit v_page_size offset (v_page - 1) * v_page_size;
end;
$$;

grant execute on function public.admin_list_chatbot_conversations(text, text, int, int, text) to anon;

-- ---------------------------------------------------------------------------
-- Every minute: if any timer has run out, wake the webhook (?task=auto-resume) to switch those
-- conversations back on and answer a customer left waiting. Checks first in SQL, so the Edge
-- Function is only called when there's actually something to do. Same extensions.http() pattern
-- as cron_dispatch_chatbot_followups (supabase_chatbot_followups.sql).

create or replace function public.cron_gma_auto_resume_bot()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_anon_key text := 'sb_publishable_QWDFggQ9ce9zm65xFEzmHA_rGaOUFQz';
  v_url text := 'https://hymcmesqgpliyyeghpgq.supabase.co/functions/v1/facebook-messenger-webhook?task=auto-resume';
begin
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

select cron.unschedule('gma-auto-resume-bot')
where exists (select 1 from cron.job where jobname = 'gma-auto-resume-bot');

select cron.schedule(
  'gma-auto-resume-bot',
  '* * * * *',
  $$select public.cron_gma_auto_resume_bot();$$
);

notify pgrst, 'reload schema';
