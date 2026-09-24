-- Per direct request: "the bot need to tell the actual stock per location" (Amaya vs GMA), the way
-- Business Central's item card shows inventory per location.
--
-- public_search_items and public_list_order_items (what Alice's search_items / list_items_in_category
-- tools call) only returned Items."QuantityInStock", a single all-warehouses total. Both now also
-- return stock_by_location, a jsonb object like {"Amaya": 4, "GMA": 0}, summed straight from
-- ItemLedgerEntries per warehouse (all variants of the item combined), the branch matched to a
-- warehouse by name the same way _push_automated_order_to_pancake / public_get_warehouse_location
-- do (Warehouses."Name" ilike '%Amaya%' / '%GMA%'). Negative balances are shown as 0. Everything
-- else in both functions is unchanged from supabase_search_items_wholesale_price.sql and
-- supabase_item_hide_from_set.sql.
--
-- Run this in the Supabase SQL Editor (needs supabase_item_ledger_entries.sql already applied).

drop function if exists public.public_search_items(text);

create or replace function public.public_search_items(p_query text)
returns table(code text, name text, description text, category_code text, price numeric, images text, quantity_in_stock int, has_variants boolean, wholesale_price numeric, stock_by_location jsonb)
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
    case when coalesce(c."IsWholesaleApplicable", false) then i."WholesalePrice" else null end,
    (
      select jsonb_object_agg(b.branch, coalesce((
        select greatest(sum(e."Quantity"), 0)::int
        from public."ItemLedgerEntries" e
        join public."Warehouses" w on w."ID" = e."WarehouseId"
        where e."ItemCode" = i."Code" and w."Name" ilike '%' || b.branch || '%'
      ), 0))
      from (values ('Amaya'), ('GMA')) as b(branch)
    )
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

drop function if exists public.public_list_order_items(text);

create or replace function public.public_list_order_items(p_category_code text)
returns table(code text, name text, description text, price numeric, images text, quantity_in_stock int, stock_by_location jsonb)
language sql
security definer
set search_path = public, extensions
stable
as $$
  select
    i."Code"::text,
    coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code")::text,
    i."Description"::text,
    coalesce(i."RetailPrice", i."Price", 0)::numeric,
    i."Images"::text,
    i."QuantityInStock",
    (
      select jsonb_object_agg(b.branch, coalesce((
        select greatest(sum(e."Quantity"), 0)::int
        from public."ItemLedgerEntries" e
        join public."Warehouses" w on w."ID" = e."WarehouseId"
        where e."ItemCode" = i."Code" and w."Name" ilike '%' || b.branch || '%'
      ), 0))
      from (values ('Amaya'), ('GMA')) as b(branch)
    )
  from public."Items" i
  where i."IsActive" is true
    and trim(coalesce(i."CategoryCode", '')) = trim(p_category_code)
    and i."HideFromSet" is not true
  order by 2;
$$;

grant execute on function public.public_list_order_items(text) to anon;
