-- Alice: stock per variant / SKU per branch - per "when alice is asked how many aquariums can you detail it
-- per location, no. of stocks per variant / sku".
--
-- public_search_items and public_list_order_items (Alice's search_items / list_items_in_category tools) gain
-- stock_by_variant: a jsonb array, one element per variant that has stock at Amaya or GMA, e.g.
--   [{"variant": "AQ-036 - STANDARD-5G (16x8x10in, 3MM GLASS)", "sku": "AQ-036-5G", "variant_id": "...", "Amaya": 2, "GMA": 1}]
-- Same source of truth as stock_by_location (supabase_chatbot_stock_from_serials.sql):
--   AQUARIUM / STAND / SUMP -> IN_STOCK ItemSerialTracking rows grouped by VariantCode (= Variants.VariationId);
--                              name prefers the serial's ItemDescription snapshot over Variants.VariantName,
--                              same as staff_get_serial_item_counts_by_location (VariantName is often generic).
--   everything else         -> ItemLedgerEntries grouped by VariantId (negative per-branch balances shown as 0).
-- Units with no variant show as "(no variant)". null when the item has no variant-level stock at all (item has
-- no variants) - stock_by_location already covers those. Variants with 0 at both branches are left out.
-- Everything else in both functions is unchanged from supabase_chatbot_stock_from_serials.sql.
--
-- Run AFTER supabase_chatbot_stock_from_serials.sql. Safe to re-run.

create or replace function public._chatbot_item_stock_by_variant(p_item_code text, p_category_code text)
returns jsonb
language sql
security definer
set search_path = public, extensions
stable
as $$
  with src as (
    select nullif(trim(s."VariantCode"), '') as vc,
           nullif(trim(s."ItemDescription"), '') as descr,
           case when s."Location" ilike '%Amaya%' then 'Amaya' when s."Location" ilike '%GMA%' then 'GMA' end as branch,
           1::numeric as qty
    from public."ItemSerialTracking" s
    where upper(trim(coalesce(p_category_code, ''))) in ('AQUARIUM', 'STAND', 'SUMP')
      and s."ItemCode" = p_item_code
      and upper(s."Status") = 'IN_STOCK'
    union all
    select nullif(trim(e."VariantId"), ''),
           null::text,
           case when w."Name" ilike '%Amaya%' then 'Amaya' when w."Name" ilike '%GMA%' then 'GMA' end,
           e."Quantity"
    from public."ItemLedgerEntries" e
    join public."Warehouses" w on w."ID" = e."WarehouseId"
    where upper(trim(coalesce(p_category_code, ''))) not in ('AQUARIUM', 'STAND', 'SUMP')
      and e."ItemCode" = p_item_code
  ),
  per_variant as (
    select vc,
           max(descr) as descr,
           greatest(coalesce(sum(qty) filter (where branch = 'Amaya'), 0), 0)::int as amaya,
           greatest(coalesce(sum(qty) filter (where branch = 'GMA'), 0), 0)::int as gma
    from src
    group by vc
  ),
  labelled as (
    select pv.vc, v."SKU" as sku, pv.amaya, pv.gma,
           coalesce(pv.descr, nullif(trim(v."VariantName"), ''), case when pv.vc is null then '(no variant)' else pv.vc end) as label
    from per_variant pv
    left join public."Variants" v on v."VariationId" = pv.vc
    where pv.amaya > 0 or pv.gma > 0
  )
  select case
    when not exists (select 1 from labelled where vc is not null) then null
    else (
      select jsonb_agg(jsonb_build_object('variant', l.label, 'sku', l.sku, 'variant_id', l.vc, 'Amaya', l.amaya, 'GMA', l.gma)
                       order by l.label)
      from labelled l
    )
  end;
$$;

revoke all on function public._chatbot_item_stock_by_variant(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------

drop function if exists public.public_search_items(text);

create or replace function public.public_search_items(p_query text)
returns table(code text, name text, description text, category_code text, price numeric, images text, quantity_in_stock int, has_variants boolean, wholesale_price numeric, stock_by_location jsonb, stock_by_variant jsonb)
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
    case
      when upper(trim(coalesce(i."CategoryCode", ''))) in ('AQUARIUM', 'STAND', 'SUMP') then (
        select count(*)::int from public."ItemSerialTracking" s
        where s."ItemCode" = i."Code" and upper(s."Status") = 'IN_STOCK'
      )
      else i."QuantityInStock"
    end,
    exists(select 1 from public."Variants" vr where vr."MainItemCode" = i."Code"),
    case when coalesce(c."IsWholesaleApplicable", false) then i."WholesalePrice" else null end,
    (
      select jsonb_object_agg(b.branch, case
        when upper(trim(coalesce(i."CategoryCode", ''))) in ('AQUARIUM', 'STAND', 'SUMP') then (
          select count(*)::int
          from public."ItemSerialTracking" s
          where s."ItemCode" = i."Code" and upper(s."Status") = 'IN_STOCK'
            and s."Location" ilike '%' || b.branch || '%'
        )
        else coalesce((
          select greatest(sum(e."Quantity"), 0)::int
          from public."ItemLedgerEntries" e
          join public."Warehouses" w on w."ID" = e."WarehouseId"
          where e."ItemCode" = i."Code" and w."Name" ilike '%' || b.branch || '%'
        ), 0)
      end)
      from (values ('Amaya'), ('GMA')) as b(branch)
    ),
    public._chatbot_item_stock_by_variant(i."Code", i."CategoryCode")
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
returns table(code text, name text, description text, price numeric, images text, quantity_in_stock int, stock_by_location jsonb, stock_by_variant jsonb)
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
    case
      when upper(trim(coalesce(i."CategoryCode", ''))) in ('AQUARIUM', 'STAND', 'SUMP') then (
        select count(*)::int from public."ItemSerialTracking" s
        where s."ItemCode" = i."Code" and upper(s."Status") = 'IN_STOCK'
      )
      else i."QuantityInStock"
    end,
    (
      select jsonb_object_agg(b.branch, case
        when upper(trim(coalesce(i."CategoryCode", ''))) in ('AQUARIUM', 'STAND', 'SUMP') then (
          select count(*)::int
          from public."ItemSerialTracking" s
          where s."ItemCode" = i."Code" and upper(s."Status") = 'IN_STOCK'
            and s."Location" ilike '%' || b.branch || '%'
        )
        else coalesce((
          select greatest(sum(e."Quantity"), 0)::int
          from public."ItemLedgerEntries" e
          join public."Warehouses" w on w."ID" = e."WarehouseId"
          where e."ItemCode" = i."Code" and w."Name" ilike '%' || b.branch || '%'
        ), 0)
      end)
      from (values ('Amaya'), ('GMA')) as b(branch)
    ),
    public._chatbot_item_stock_by_variant(i."Code", i."CategoryCode")
  from public."Items" i
  where i."IsActive" is true
    and trim(coalesce(i."CategoryCode", '')) = trim(p_category_code)
    and i."HideFromSet" is not true
  order by 2;
$$;

grant execute on function public.public_list_order_items(text) to anon;

notify pgrst, 'reload schema';
