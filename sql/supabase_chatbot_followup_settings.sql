-- AI Messenger chatbot: follow-up behavior settings, editable from the AI Bot Setup admin page
-- without a code deploy. Separate table from ChatbotAiSettings (persona/tone) - same reasoning as
-- ChatbotStoreInfo being split out: a distinct concern with its own save button on the same page.
--
-- Read by supabase/functions/chatbot-followup-dispatcher (the pg_cron-triggered function that
-- detects and sends follow-ups) and by facebook-messenger-webhook's schedule_follow_up tool (to
-- check CommittedEnabled before letting the bot promise a callback). See
-- sql/supabase_chatbot_followups.sql for the queue table and detection columns this drives.
--
-- Four follow-up types, each independently toggled with its own delay:
--   Abandoned    - customer went quiet after the bot's last message; nudge them after N minutes.
--   Escalation   - conversation was escalated to staff (escalate_to_staff tool); check in after
--                  N minutes in case staff haven't followed up yet.
--   PendingOrder - an AutomatedOrders row is still Status='New' (unconfirmed/no payment yet) after
--                  N minutes; remind the customer to complete it. AutomatedOrders has no
--                  balance/payment-due tracking today (that only exists on the separate,
--                  Psid-less AdvanceOrders/POS table) - this is the closest real signal: an order
--                  the bot took that staff hasn't confirmed/moved off "New" yet.
--   Committed    - the bot itself decided mid-conversation to promise a follow-up (e.g. "I'll check
--                  back tomorrow"), via the schedule_follow_up tool. This toggle is a kill switch
--                  for that capability; there's no delay setting since the bot picks the time.
--
-- FollowUpDirections: free-text tone/instructions applied only when composing follow-up messages
-- (e.g. "keep it low-pressure, never ask twice in one day") - same idea as
-- ChatbotAiSettings.CustomDirections but scoped to this one feature so store owners can tune
-- follow-ups without touching the bot's general persona.

create table if not exists public."ChatbotFollowUpSettings" (
    "Id" smallint primary key default 1 check ("Id" = 1),
    "AbandonedEnabled" boolean not null default false,
    "AbandonedDelayMinutes" int not null default 180,
    "EscalationEnabled" boolean not null default false,
    "EscalationDelayMinutes" int not null default 1440,
    "PendingOrderEnabled" boolean not null default false,
    "PendingOrderDelayMinutes" int not null default 720,
    "CommittedEnabled" boolean not null default true,
    "FollowUpDirections" text,
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

alter table public."ChatbotFollowUpSettings" enable row level security;

drop policy if exists "Public read" on public."ChatbotFollowUpSettings";
create policy "Public read" on public."ChatbotFollowUpSettings"
    for select to anon, authenticated using (true);

-- No insert/update/delete policy for anon/authenticated - writes only via the RPC below.
revoke insert, update, delete on public."ChatbotFollowUpSettings" from anon, authenticated;

comment on table public."ChatbotFollowUpSettings" is 'Single-row chatbot follow-up settings (which follow-up types are on, their delays, and tone directions) - publicly readable, edited only via admin_upsert_chatbot_followup_settings.';

drop function if exists public.admin_upsert_chatbot_followup_settings(text, text, boolean, int, boolean, int, boolean, int, boolean, text);

create or replace function public.admin_upsert_chatbot_followup_settings(
  p_admin_username text,
  p_admin_password text,
  p_abandoned_enabled boolean,
  p_abandoned_delay_minutes int,
  p_escalation_enabled boolean,
  p_escalation_delay_minutes int,
  p_pending_order_enabled boolean,
  p_pending_order_delay_minutes int,
  p_committed_enabled boolean,
  p_follow_up_directions text
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

  insert into public."ChatbotFollowUpSettings"
    ("Id", "AbandonedEnabled", "AbandonedDelayMinutes", "EscalationEnabled", "EscalationDelayMinutes",
     "PendingOrderEnabled", "PendingOrderDelayMinutes", "CommittedEnabled", "FollowUpDirections",
     "UpdatedBy", "UpdatedAtUtc")
  values
    (1, coalesce(p_abandoned_enabled, false), greatest(coalesce(p_abandoned_delay_minutes, 180), 15),
     coalesce(p_escalation_enabled, false), greatest(coalesce(p_escalation_delay_minutes, 1440), 15),
     coalesce(p_pending_order_enabled, false), greatest(coalesce(p_pending_order_delay_minutes, 720), 15),
     coalesce(p_committed_enabled, true), p_follow_up_directions,
     p_admin_username, now())
  on conflict ("Id") do update set
    "AbandonedEnabled" = excluded."AbandonedEnabled",
    "AbandonedDelayMinutes" = excluded."AbandonedDelayMinutes",
    "EscalationEnabled" = excluded."EscalationEnabled",
    "EscalationDelayMinutes" = excluded."EscalationDelayMinutes",
    "PendingOrderEnabled" = excluded."PendingOrderEnabled",
    "PendingOrderDelayMinutes" = excluded."PendingOrderDelayMinutes",
    "CommittedEnabled" = excluded."CommittedEnabled",
    "FollowUpDirections" = excluded."FollowUpDirections",
    "UpdatedBy" = excluded."UpdatedBy",
    "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

grant execute on function public.admin_upsert_chatbot_followup_settings(text, text, boolean, int, boolean, int, boolean, int, boolean, text) to anon;
