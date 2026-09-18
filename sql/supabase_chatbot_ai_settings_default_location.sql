-- Lets the AI Bot Setup page (docs/ai-bot-setup.html) configure which branch (Amaya or GMA) the
-- chatbot defaults to when placing an order and the customer hasn't specified one, instead of the
-- hardcoded 'Amaya' fallback that was baked into supabase/functions/_shared/chatbot-engine.ts's
-- create_order tool. Per direct request - this bot only serves the GMA Facebook Page today, so
-- every order it places should default to the GMA branch - but a code-deploy-free setting (same
-- single-row pattern as every other knob on this table, see supabase_chatbot_ai_settings_table.sql)
-- means that can change later (e.g. if Amaya ever gets its own bot/page) without another deploy.
--
-- Defaults to 'GMA' on the existing row (not 'Amaya', the OLD hardcoded behavior) - this migration
-- is explicitly changing that default, not preserving it.

alter table public."ChatbotAiSettings" add column if not exists "DefaultLocation" varchar(20) not null default 'GMA';

update public."ChatbotAiSettings" set "DefaultLocation" = 'GMA' where "Id" = 1 and "DefaultLocation" is null;

comment on column public."ChatbotAiSettings"."DefaultLocation" is 'Which branch (Amaya or GMA) the chatbot uses for create_order/compute_delivery_quote/etc when the customer hasn''t specified one - read by buildSystemPrompt (DEFAULT BRANCH line) and used as executeTool''s create_order fallback in supabase/functions/_shared/chatbot-engine.ts.';

drop function if exists public.admin_upsert_chatbot_ai_settings(text, text, text, text, text, text, text);

create or replace function public.admin_upsert_chatbot_ai_settings(
  p_admin_username text,
  p_admin_password text,
  p_bot_name text,
  p_communication_style text,
  p_greeting_message text,
  p_custom_directions text,
  p_ai_model text,
  p_default_location text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_default_location text := coalesce(nullif(trim(p_default_location), ''), 'GMA');
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;
  if v_default_location not in ('Amaya', 'GMA') then
    raise exception 'Default location must be Amaya or GMA.';
  end if;

  insert into public."ChatbotAiSettings"
    ("Id", "BotName", "CommunicationStyle", "GreetingMessage", "CustomDirections", "AiModel", "DefaultLocation", "UpdatedBy", "UpdatedAtUtc")
  values
    (1, p_bot_name, p_communication_style, p_greeting_message, p_custom_directions, p_ai_model, v_default_location, p_admin_username, now())
  on conflict ("Id") do update set
    "BotName" = excluded."BotName",
    "CommunicationStyle" = excluded."CommunicationStyle",
    "GreetingMessage" = excluded."GreetingMessage",
    "CustomDirections" = excluded."CustomDirections",
    "AiModel" = excluded."AiModel",
    "DefaultLocation" = excluded."DefaultLocation",
    "UpdatedBy" = excluded."UpdatedBy",
    "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

grant execute on function public.admin_upsert_chatbot_ai_settings(text, text, text, text, text, text, text, text) to anon;
