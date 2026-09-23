-- Adds public_list_wholesale_items(), a new RPC backing a new Alice tool (list_wholesale_prices,
-- chatbot-engine.ts) for when a customer asks for the WHOLE wholesale price list rather than a
-- single item. Previously Alice only had search_items (per-item lookup, requires a matching
-- keyword - a query like "wholesale price list" matches nothing) and list_items_in_category
-- (public_list_order_items, which never selects WholesalePrice at all) - neither could answer
-- "what's your wholesale price list" and Alice fell back to saying there's no wholesale price.
--
-- Same data-layer gating as public_search_items (supabase_search_items_wholesale_price.sql):
-- only items in a category with "IsWholesaleApplicable" = true (currently AQUARIUM/STAND/SUMP -
-- see supabase_category_wholesale_flag.sql) AND with an actual "WholesalePrice" set are returned.
-- Whether/when Alice is allowed to share this list is enforced separately in the system prompt
-- (buildSystemPrompt, supabase/functions/_shared/chatbot-engine.ts).
--
-- Run this in the Supabase SQL Editor.

drop function if exists public.public_list_wholesale_items();

create or replace function public.public_list_wholesale_items()
returns table(code text, name text, category_code text, wholesale_price numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select
    i."Code"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")::text,
    i."CategoryCode"::text,
    i."WholesalePrice"::numeric
  from public."Items" i
  join public."Categories" c on trim(coalesce(c."Code", '')) = trim(coalesce(i."CategoryCode", ''))
  where i."IsActive" is true
    and coalesce(c."IsWholesaleApplicable", false) is true
    and i."WholesalePrice" is not null
  order by i."CategoryCode", i."Name";
$$;

grant execute on function public.public_list_wholesale_items() to anon;
