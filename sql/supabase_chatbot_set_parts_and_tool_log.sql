-- Vic / Alice: stop double-punching a set's own parts, and keep a record of every tool the bot runs.
--
-- AO-00121: the customer ordered the 15g Topfilter Package (SET-019, P2,999 - its package already has the
-- AST-005 Dual Stand), picked Black Paint for the stand, and Vic added AST-005 again as its own P1,290 line
-- to carry the color. Then it said "naayos ko na po" when it had only QUOTED the fix (modify_order apply=false)
-- - and nobody could check, because tool calls weren't saved anywhere.
--
-- 1. bot_set_part_codes: the item codes inside each set's package (same package match as set explosion,
--    _resolve_set_package). create_order / modify_order refuse a separate line for a part the set already
--    has, unless the customer asked for an EXTRA one (extra_to_set).
-- 2. ChatbotToolCalls: one row per tool the bot runs (Messenger, website widget, sandbox...) - name, input,
--    result, and whether it changed anything. Kept 90 days.
--
-- Run AFTER supabase_aquarium_sets_portal_owned.sql. Safe to re-run.
-- Needs the bot functions redeployed (chatbot-engine.ts) - until then nothing calls these.

-- ---------------------------------------------------------------------------
-- 1. Parts of each set
create or replace function public.bot_set_part_codes(p_set_codes text[])
returns table(set_code text, item_code text, item_name text)
language sql
stable
security definer
set search_path = public
as $$
  select i."Code"::text, trim(l."ItemNo")::text, coalesce(nullif(trim(it."Name"), ''), trim(l."ItemNo"))::text
    from public."Items" i
    join public."CompleteAquariumSetLine" l
      on l."PackageName" = public._resolve_set_package(i."VariationId", i."Code")
    left join public."Items" it on it."Code" = trim(l."ItemNo")
   where i."Code" = any(p_set_codes)
     and trim(coalesce(l."ItemNo", '')) <> '';
$$;

revoke all on function public.bot_set_part_codes(text[]) from public, anon, authenticated;
grant execute on function public.bot_set_part_codes(text[]) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Tool-call log
create table if not exists public."ChatbotToolCalls" (
    "Id" bigint generated always as identity primary key,
    "Psid" varchar(255),
    "ToolName" varchar(100) not null,
    "Input" jsonb,
    "Result" text,
    "Simulated" boolean not null default false,
    "CreatedAtUtc" timestamptz not null default now()
);

create index if not exists "IX_ChatbotToolCalls_Psid_CreatedAtUtc" on public."ChatbotToolCalls" ("Psid", "CreatedAtUtc" desc);
create index if not exists "IX_ChatbotToolCalls_CreatedAtUtc" on public."ChatbotToolCalls" ("CreatedAtUtc");

alter table public."ChatbotToolCalls" enable row level security;
revoke all on public."ChatbotToolCalls" from anon, authenticated;

comment on table public."ChatbotToolCalls" is 'Every tool Vic/Alice ran (chatbot-engine.ts runChatbotTurn): input + result, for checking what the bot actually did vs what it told the customer. Rows older than 90 days are purged by the bot itself.';

notify pgrst, 'reload schema';

-- Verification - one result.
select 'set parts' as section, s.set_code as name, string_agg(s.item_code || ' ' || s.item_name, ', ') as detail
  from public.bot_set_part_codes(array['SET-019']) s
 group by s.set_code
union all
select 'table', 'ChatbotToolCalls', case when to_regclass('public."ChatbotToolCalls"') is not null then 'ready' else 'MISSING' end;
