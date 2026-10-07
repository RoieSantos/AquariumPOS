-- Alice ("list_aquarium_sets" tool): the ready-made SET-category packages (complete aquarium setups)
-- with their fixed price, stock and what's inside each one - per "we can let the ai bot offer SET
-- Category products" for a customer asking for a complete setup.
--
-- Same item filter as public_list_order_items (active, CategoryCode 'SET', not HideFromSet), so the
-- sets Alice offers are the ones she can already list/order. "includes" comes from the package
-- (CompleteAquariumSetHeader/Line) the set resolves to via _resolve_set_package - item names and
-- quantities only, never the per-line Price (the set is sold at its own price only).
-- includes = null means no package is linked yet - Alice falls back to the item's description.
--
-- Run AFTER supabase_online_order_set_explode.sql (needs _resolve_set_package). Safe to re-run.

create or replace function public.public_list_aquarium_sets()
returns table(code text, name text, description text, price numeric, quantity_in_stock int, includes jsonb)
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
    i."QuantityInStock",
    (select jsonb_agg(jsonb_build_object('item', coalesce(nullif(trim(l."ItemName"), ''), l."ItemNo"), 'qty', l."Quantity")
                      order by l."EntryNo")
       from public."CompleteAquariumSetLine" l
      where l."PackageName" = public._resolve_set_package(i."VariationId", i."Code")
        and trim(coalesce(l."ItemNo", '')) <> '')
  from public."Items" i
  where i."IsActive" is true
    and upper(trim(coalesce(i."CategoryCode", ''))) = 'SET'
    and i."HideFromSet" is not true
  order by 2;
$$;
grant execute on function public.public_list_aquarium_sets() to anon;

-- Quick look after running (this is the result the editor shows):
select code, name, price, quantity_in_stock,
       coalesce(jsonb_array_length(includes), 0) as included_lines
from public.public_list_aquarium_sets();
