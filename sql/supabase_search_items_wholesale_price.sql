-- Adds a wholesale_price column to public_search_items (the RPC Alice's search_items tool calls),
-- per direct request: "allow sharing wholesale price only" (a deliberate, narrow carve-out from the
-- earlier "never Cost/WholesalePrice/PromoPrice" rule - see supabase_chatbot_search_items_variants.
-- sql's header comment - Cost and PromoPrice stay excluded, only WholesalePrice is now let through).
--
-- Gated at the DATA layer, not just by prompt instructions: a row only gets a non-null
-- wholesale_price when its category's "IsWholesaleApplicable" flag is true (supabase_category_
-- wholesale_flag.sql - currently Aquarium/Stand/Sump). An item in a non-wholesale-eligible category
-- always returns null here even if it happens to have a WholesalePrice value set on it. Whether
-- Alice actually MENTIONS it (only when the customer explicitly asks about wholesale/bulk pricing,
-- never volunteered) is enforced separately in the system prompt (buildSystemPrompt,
-- supabase/functions/_shared/chatbot-engine.ts) - this file only controls what data COULD reach her
-- at all, same defense-in-depth split the codebase already uses for Cost/PromoPrice.
--
-- Matching/ranking logic is copied verbatim from supabase_chatbot_search_items_variants.sql,
-- unchanged - only the SELECT list and RETURNS TABLE signature gained a column.
--
-- Run this in the Supabase SQL Editor.

drop function if exists public.public_search_items(text);

create or replace function public.public_search_items(p_query text)
returns table(code text, name text, description text, category_code text, price numeric, images text, quantity_in_stock int, has_variants boolean, wholesale_price numeric)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with raw_words as (
    select raw_word
    from unnest(regexp_split_to_array(trim(p_query), '\W+')) as raw_word
    union all
    -- "<digits> gal/gallon/gallons" (any spacing) also contributes "<digits>G" - matches this
    -- catalog's own NNNG size-code convention, e.g. "5 gallon" -> also search "5G".
    select (m)[1] || 'G'
    from regexp_matches(p_query, '(\d+)\s*gal(?:lons?)?', 'gi') as m
  ),
  words as (
    select distinct expanded.word
    from raw_words rw
    cross join lateral (
      select case
        when length(rw.raw_word) > 3 and rw.raw_word ~* 's$' then left(rw.raw_word, length(rw.raw_word) - 1)
        else rw.raw_word
      end as stem
    ) stemmed
    cross join lateral (
      values
        (stemmed.stem),
        (case lower(stemmed.stem) when 'tank' then 'aquarium' when 'aquarium' then 'tank' else null end)
    ) as expanded(word)
    where expanded.word is not null
      and length(expanded.word) >= 2
  )
  select
    i."Code"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")::text,
    i."Description"::text,
    i."CategoryCode"::text,
    coalesce(i."RetailPrice", i."Price", 0)::numeric,
    i."Images"::text,
    i."QuantityInStock",
    exists(select 1 from public."Variants" vr where vr."MainItemCode" = i."Code"),
    case when coalesce(c."IsWholesaleApplicable", false) then i."WholesalePrice" else null end
  from public."Items" i
  left join public."Categories" c on trim(coalesce(c."Code", '')) = trim(coalesce(i."CategoryCode", ''))
  where i."IsActive" is true
    and exists (
      select 1 from words w
      where i."Name" ~* ('\y' || w.word || 's?\y')
         or i."Description" ~* ('\y' || w.word || 's?\y')
         or i."SKU" ~* ('\y' || w.word || 's?\y')
         or i."Code" ~* ('\y' || w.word || 's?\y')
         or c."Description" ~* ('\y' || w.word || 's?\y')
    )
  order by
    case
      when exists (
        select 1 from words w
        where w.word ~ '[0-9]'
          and (
            i."Name" ~* ('\y' || w.word || 's?\y')
            or i."Description" ~* ('\y' || w.word || 's?\y')
            or i."SKU" ~* ('\y' || w.word || 's?\y')
            or i."Code" ~* ('\y' || w.word || 's?\y')
          )
      ) then 0
      when exists (select 1 from words w where trim(i."CategoryCode") ~* ('^' || w.word || 's?$')) then 1
      when exists (
        select 1 from words w
        where i."Name" ~* ('\y' || w.word || 's?\y')
           or i."Description" ~* ('\y' || w.word || 's?\y')
           or i."SKU" ~* ('\y' || w.word || 's?\y')
           or i."Code" ~* ('\y' || w.word || 's?\y')
      ) then 2
      else 3
    end,
    i."Name"
  limit 20;
$$;

grant execute on function public.public_search_items(text) to anon;
