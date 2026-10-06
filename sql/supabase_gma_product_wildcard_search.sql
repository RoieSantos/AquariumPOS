-- GMA Conversations: wildcard product search - per "can you do a better wild card filter" (typing "75" found
-- nothing, though there are several STANDARD-75G items).
--
-- public_search_items (Alice's search_items tool) matches WHOLE words only (\y75s?\y needs a word boundary
-- after 75, so "75" never hits "75G"). Rather than change what the bot finds, the GMA page's two product
-- searches (Product List panel + Create Order tab) now use this separate staff_search_items_wildcard:
--   - every word typed must appear SOMEWHERE (any order, partial match: "75" hits "75G", "std 75" hits
--     "STANDARD-75G") in the item's name, description, SKU, code, category, or any of its variants'
--     names/SKUs (so "black" finds the aquarium with a Black Sealant variant)
--   - "*" works as an explicit wildcard inside a word ("48*20" hits "48x18x20"); "x" and "×" are treated
--     the same, so "48x18" hits "48×18×20in"
--   - ranked: name starts with the whole query, then name contains it, then the rest; alphabetical within
--   - EMPTY search = the default list shown when the Product List opens (per "add default product list upon
--     open"): best sellers, by units sold (ledger 'Sale' entries) in the last 90 days, then the rest A-Z
-- Returns exactly the same columns as public_search_items (stock_by_location, stock_by_variant, ...), so
-- it's a drop-in for the page. Limit 30.
--
-- Run AFTER supabase_chatbot_stock_by_variant.sql. Safe to re-run.
-- Ends with ONE result: the default (empty-search) list, then what "75" finds.

create or replace function public.staff_search_items_wildcard(p_query text)
returns table(code text, name text, description text, category_code text, price numeric, images text, quantity_in_stock int, has_variants boolean, wholesale_price numeric, stock_by_location jsonb, stock_by_variant jsonb)
language sql
security definer
set search_path = public, extensions
stable
as $$
  with q as (
    select lower(translate(trim(coalesce(p_query, '')), '×', 'x')) as full_q
  ),
  words as (
    -- each word -> an ILIKE pattern: escape \ % _, then * becomes %
    select '%' || replace(replace(replace(replace(w, '\', '\\'), '%', '\%'), '_', '\_'), '*', '%') || '%' as pat
    from q, unnest(regexp_split_to_array(q.full_q, '\s+')) as w
    where w <> ''
  ),
  hay as (
    select i."Code" as code,
           lower(translate(concat_ws(' ', i."Name", i."Description", i."SKU", i."Code", i."CategoryCode", c."Description",
             (select string_agg(concat_ws(' ', v."VariantName", v."SKU"), ' ')
                from public."Variants" v where v."MainItemCode" = i."Code")), '×', 'x')) as text_all,
           lower(translate(coalesce(nullif(trim(i."Name"), ''), nullif(trim(i."Description"), ''), i."Code"), '×', 'x')) as name_l
    from public."Items" i
    left join public."Categories" c on trim(coalesce(c."Code", '')) = trim(coalesce(i."CategoryCode", ''))
    where i."IsActive" is true
  ),
  -- Default list (empty search): units sold in the last 90 days per item - a variant's own item row
  -- rolls up to its parent, since the picker lists the parent.
  sold as (
    select coalesce((select v."MainItemCode" from public."Variants" v
                      where v."ItemCode" = e."ItemCode" and v."MainItemCode" <> e."ItemCode" limit 1),
                    e."ItemCode") as code,
           -sum(e."Quantity") as qty
    from public."ItemLedgerEntries" e
    where e."EntryType" = 'Sale' and e."PostingDate" >= current_date - 90
    group by 1
  ),
  hits as (
    select h.code, h.name_l, 0::numeric as sold_qty
    from hay h
    where exists (select 1 from words)
      and not exists (select 1 from words w where h.text_all not ilike w.pat escape '\')
    union all
    select h.code, h.name_l, coalesce((select sum(s.qty) from sold s where s.code = h.code), 0)
    from hay h
    where not exists (select 1 from words)
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
  from hits h
  join public."Items" i on i."Code" = h.code
  left join public."Categories" c on trim(coalesce(c."Code", '')) = trim(coalesce(i."CategoryCode", ''))
  cross join q
  order by
    h.sold_qty desc,
    case when h.name_l like q.full_q || '%' then 0 when position(q.full_q in h.name_l) > 0 then 1 else 2 end,
    h.name_l
  limit 30;
$$;

grant execute on function public.staff_search_items_wildcard(text) to anon;

notify pgrst, 'reload schema';

select 'default list' as section, code, name, category_code, price, has_variants, stock_by_location
  from public.staff_search_items_wildcard('')
union all
select 'search "75"', code, name, category_code, price, has_variants, stock_by_location
  from public.staff_search_items_wildcard('75');
