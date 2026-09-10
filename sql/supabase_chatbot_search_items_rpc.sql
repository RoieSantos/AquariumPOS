-- AI Messenger chatbot: keyword product search, called by Claude's search_items tool
-- (supabase/functions/facebook-messenger-webhook) whenever a customer asks "do you have X" or
-- about a specific product's price/stock.
--
-- public_list_order_items (supabase_automated_orders_tables.sql:123-141) only lists by exact
-- CategoryCode - there's no free-text search RPC anywhere in this codebase yet, and a chatbot
-- needs one since customers describe what they want in their own words, not by category code.
--
-- Same "never expose Cost/WholesalePrice/PromoPrice" discipline and column set as
-- public_list_order_items - only what's safe to show a customer with no login at all leaves the
-- server. `limit 20` matters here specifically because the result feeds an LLM prompt rather than
-- a paginated UI - an unbounded ILIKE match (e.g. "fish") could return hundreds of rows and blow
-- up token cost on every such message.
--
-- v2: the original version ILIKE-matched the WHOLE query string as one substring against
-- Name/Description/SKU/Code. That's why a real customer message like "5 gallon aquarium" found
-- nothing for an item literally named "STANDARD-5G (16x8x10in, 3MM GLASS)" - the item's own Name
-- never contains that exact phrase, and "aquarium" isn't in its Name/Description at all (it's only
-- in the ITEM'S CATEGORY's label). The bot then confidently told the customer "wala kaming 5
-- gallon aquarium" even though AQ-036 exists and is in stock - a false negative, worse than no
-- search at all. Fixed two ways: (1) split the query into words and match if ANY word (2+ chars,
-- so filler single letters/digits don't cause noise) hits any searched column - OR across
-- words/columns, not AND, so a multi-word natural-language query still finds a match even if only
-- one word lines up; (2) also search the item's Category description (joined via CategoryCode),
-- since customers often describe items by category ("aquarium", "filter") rather than by whatever
-- internal name/code the item was given.
--
-- Not a guarantee across every possible product/phrasing - this is still plain substring matching,
-- not fuzzy search: no typo tolerance ("aquarum" won't match "aquarium") and no synonym mapping
-- ("tank" won't match an item only ever labeled "aquarium" anywhere in its data or category). It
-- only helps when at least one word in the query is a real substring of something already stored.
--
-- v3: split on any run of non-alphanumeric characters (regex \W+), not just whitespace (\s+) -
-- v2 split "aquarium?" or "5-gallon" into literal tokens "aquarium?"/"5-gallon" complete with the
-- punctuation, and ILIKE then required that exact punctuation to appear in the stored text too
-- (it never does), silently dropping that word from matching. \W+ turns "5-gallon" into two clean
-- tokens ("5" and "gallon") and strips trailing punctuation like "?" or "," from any word.
--
-- v4: live-tested against the real catalog after v3 - searching just "5g" (a very plausible
-- customer shorthand for AQ-036 "STANDARD-5G") returned 20 unrelated rows and NOT AQ-036, because
-- ILIKE '%5g%' also matches every OTHER size code that happens to end in a 5, since "5g" is a
-- literal substring of "15G", "25G", "35G", "75G", "150G", etc. - this catalog names nearly every
-- product with a NNNG-style size code, so plain substring matching on a short numeric+letter word
-- collides constantly. With `order by Name limit 20`, those collisions can fully crowd out the
-- actual match before it's ever reached. Switched from ILIKE substring matching to POSIX regex
-- word-boundary matching (~* with \y...\y) so a word only matches a whole token - "5g" now matches
-- a standalone "5G" but not the "5G" hiding inside "15G"/"25G"/etc. Trade-off: this also gives up
-- true partial-word matches (e.g. "filt" no longer matching "filter") in exchange for eliminating
-- the much more common and damaging numeric-size collisions in THIS catalog. Words coming out of
-- the \W+ split are always plain alphanumeric/underscore runs, so embedding them directly in a
-- regex here is safe - no metacharacters to escape.
--
-- v5: live-tested "tank"/"5 gallon"/"gallon" against the real catalog after v4 - all three returned
-- NOTHING for AQ-036 "STANDARD-5G (16x8x10in, 3MM GLASS)", a real, active, standalone tank (customer
-- asked "pag tank lng po?" and the bot wrongly said there was no standalone tank, only a bundle set).
-- Root cause: the word "tank" never appears anywhere in that item's Name/Description/SKU/Code, and
-- its category's own description is just the single word "Aquarium" - v4's exact-word matching has
-- no way to know a customer's "tank" means the same thing as the catalog's "Aquarium". Similarly
-- "gallon" never matches because the item only ever says "5G", never "Gallon(s)". Fixed two ways,
-- both still exact-whole-word matches (v4's "5g" vs "15G" fix stays intact):
-- (1) a small synonym table - "tank"/"tanks" also searches "aquarium" and vice versa;
-- (2) plural tolerance - strip a trailing "s" off the query word (only when longer than 3 chars, so
--     short words like "as"/"is" are untouched) and allow an optional trailing "s" on the stored
--     text side, so "gallon" matches "Gallons", "filter" matches "Filters", and either direction of
--     singular/plural lines up without needing an exact match.
--
-- v6: live-tested "5 gallon tank" (and "tank" alone) against the real catalog after v5 - fixed the
-- false negative, but created a false-CROWDING problem instead: the "tank"->"aquarium" synonym now
-- matches nearly every AQUARIUM-related item, including SET-category bundle products whose Name
-- literally contains the word "AQUARIUM" (this catalog names bundles like
-- "100GALLONS-AQUARIUM-10MM (... SETUP SET)"). With results ordered purely alphabetically and
-- capped at 20, those numeric-named bundles sort before "STANDARD-5G" and fully crowded AQ-036 out
-- of the top 20 - the bot then told the customer there was still no standalone tank, even after v5.
-- Fixed by ranking, not by narrowing the match: items whose own CategoryCode literally IS one of
-- the matched words (e.g. CategoryCode = 'AQUARIUM' for a "tank"/"aquarium" search) now sort first -
-- that's the least ambiguous "this item actually IS the thing being searched for" signal, ahead of
-- items that merely mention the word in a marketing name. Direct Name/Description/SKU/Code matches
-- rank next, and matches that only came through the category DESCRIPTION-text fallback (weakest
-- signal) rank last. All within the same `limit 20`/`security definer` shape as before.
--
-- v7: live-tested "5 gallon tank" against the real catalog after v6 - the category-code ranking
-- worked (SET bundles no longer out-rank real AQUARIUM items), but the AQUARIUM category alone has
-- 20+ active items, so the same alphabetical `limit 20` crowding just moved one level down - and
-- "STANDARD-5G" sorts AFTER "STANDARD-100G"/"STANDARD-10G" alphabetically ('1' < '5' as characters),
-- so it's still cut off. Root cause: the customer's actual size cue - the digit "5" - never survives
-- as its own word, because a lone "5" is filtered out by the `length(word) >= 2` noise guard, so
-- nothing in the query tells the ranking WHICH aquarium size was meant; a query like "tank" or
-- "5 gallon tank" degrades to "any aquarium at all" with no way to prefer the 5G one. Typing "5g" as
-- one fused token already worked fine (it survives as its own 2-char word and matches "5G" in the
-- item's own Name directly) - the gap was only ever the spelled-out/spaced phrasing.
-- Fixed by deriving a size token from the query text itself: any "<digits> gal/gallon/gallons" run
-- (regardless of spacing) also contributes a "<digits>G" word - e.g. "5 gallon" additionally
-- searches "5G", matching this catalog's own NNNG size-code convention exactly the way typing "5g"
-- already did. Combined with a new top-priority ranking tier: an item whose Name/Description/SKU/
-- Code directly matched a DIGIT-containing word (a specific size/model token, not just a generic
-- category word like "aquarium") now ranks above every plain category-level match - so a specific
-- size mention always outranks "any aquarium in stock", regardless of how many other items share the
-- category.

drop function if exists public.public_search_items(text);

create or replace function public.public_search_items(p_query text)
returns table(code text, name text, description text, category_code text, price numeric, images text, quantity_in_stock int)
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
    i."QuantityInStock"
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
