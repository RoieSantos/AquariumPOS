-- GMA Conversations' Product List panel (docs/gma-conversations.html) - per direct follow-up
-- request, lets staff pick a SPECIFIC variant of a product (e.g. a particular size/color), not just
-- the generic parent item, when a product has any.
--
-- Two changes:
-- (1) public_search_items (sql/supabase_chatbot_search_items_rpc.sql) gets one added output column,
--     has_variants - the matching/ranking logic itself (tuned across 7 iterations there) is copied
--     verbatim, unchanged, only the SELECT list and RETURNS TABLE signature gained a column.
-- (2) a new public_list_item_variants(p_item_code) lists a specific item's variants, with per-variant
--     stock resolved by joining Variants.ItemCode back onto Items.QuantityInStock - Variants itself
--     has no stock column of its own (see sql/supabase_warehouses_items_tables.sql); ItemCode is the
--     Pancake-sync-resolved link to that variant's own Items row (see supabase_pancake_manual_sync.
--     sql's tmp_pancake_variants_resolved), so a variant with an unresolved ItemCode has no stock
--     figure available and shows as null (rendered as "Out of stock" client-side, same as 0).
--
-- No admin session required for either - same "safe to show any signed-out visitor" column
-- discipline as public_search_items (never Cost/WholesalePrice/PromoPrice).

drop function if exists public.public_search_items(text);

create or replace function public.public_search_items(p_query text)
returns table(code text, name text, description text, category_code text, price numeric, images text, quantity_in_stock int, has_variants boolean)
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
    exists(select 1 from public."Variants" vr where vr."MainItemCode" = i."Code")
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

-- ---------------------------------------------------------------------------
-- public_list_item_variants: a product's variants, for the Product List panel's expand-to-choose-a-
-- variant UI.
-- ---------------------------------------------------------------------------
drop function if exists public.public_list_item_variants(text);

create or replace function public.public_list_item_variants(p_item_code text)
returns table(variation_id text, sku text, variant_name text, price numeric, images text, quantity_in_stock int)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select
    v."VariationId"::text,
    v."SKU"::text,
    coalesce(nullif(trim(v."VariantName"), ''), v."SKU", v."VariationId")::text,
    coalesce(v."Price", 0)::numeric,
    coalesce(nullif(trim(v."Images"), ''), i."Images")::text,
    i."QuantityInStock"
  from public."Variants" v
  left join public."Items" i on i."Code" = v."ItemCode"
  where v."MainItemCode" = p_item_code
  order by v."VariantName"
  limit 50;
$$;

grant execute on function public.public_list_item_variants(text) to anon;
