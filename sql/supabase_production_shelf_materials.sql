-- *** NOT USED - no need to run. *** Built from a misreading of "show the number of black and clear
-- sealant too per shelf": Black / Clear turned out to be VARIANTS of the aquarium (e.g. 75G black
-- sealant vs clear sealant), which the page now splits each rack's serial count by
-- (docs/js/productionShelfMap.js colourBreakdown). Kept only in case sealant stock is wanted later;
-- if it was already run, its table/functions are harmless and unused.
--
-- Production Shelf Map: MATERIALS per shelf - per "in the production shelf map can you show the
-- number of black and clear sealant too per shelf?".
--
-- Sealant isn't serial-tracked, so its stock comes from the Item Ledger, which knows how much is at a
-- LOCATION (warehouse), not on which rack. So materials are shown per shelf: a strip above the map
-- with each chosen item's live on-hand at the shelf's warehouse, e.g. "Black Sealant 24 · Clear
-- Sealant 18".
--
--   ProductionShelfMaterials - which items a shelf shows (item, optional variant, optional label).
--   staff_get_production_shelf_materials   - every shelf's materials with on-hand (any staff).
--   admin_set_production_shelf_materials   - replace a shelf's list (Super User / Production Manager).
--
-- On-hand = SUM(ItemLedgerEntries.Quantity) for the item at the shelf's warehouse - all variants when
-- no variant is picked, just that variant otherwise (resolved the same way the ledger stores it).
--
-- Also seeds every shelf that has no materials yet with the black and clear VARIANTS of the sealant
-- (or silicone) item(s) - check the strip and adjust with the Materials button.
--
-- Run AFTER supabase_production_shelf_serial_counts.sql. Safe to re-run.

create table if not exists public."ProductionShelfMaterials" (
    "Id" serial primary key,
    "ShelfId" int not null references public."ProductionShelves" ("Id") on delete cascade,
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100),
    "Label" varchar(100),
    "SortOrder" int not null default 0
);

create index if not exists "IX_ProductionShelfMaterials_Shelf" on public."ProductionShelfMaterials" ("ShelfId");

alter table public."ProductionShelfMaterials" enable row level security;
revoke all on public."ProductionShelfMaterials" from anon, authenticated;

-- ============================================================================
-- Reading
-- ============================================================================

drop function if exists public.staff_get_production_shelf_materials(text, text);

create or replace function public.staff_get_production_shelf_materials(p_admin_username text, p_admin_password text)
returns table(shelf_id int, item_code text, item_name text, variant_id text, variant_name text, label text,
              on_hand numeric, sort_order int)
language plpgsql
security definer
set search_path = public, extensions
stable
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select m."ShelfId", m."ItemCode"::text, i."Name"::text, m."VariantId"::text,
           coalesce(nullif(trim(v."VariantName"), ''), v."SKU")::text, m."Label"::text,
           coalesce((
             select sum(e."Quantity")
             from public."ItemLedgerEntries" e
             where e."WarehouseId" = sh."WarehouseId"
               -- A variant with its own item row is stored under that item (no variant id); one that
               -- shares its parent's row is stored under the parent with its variant id.
               and e."ItemCode" = coalesce(nullif(trim(v."ItemCode"), ''), m."ItemCode")
               and (m."VariantId" is null or e."VariantId" is null or e."VariantId" = m."VariantId")
           ), 0),
           m."SortOrder"
    from public."ProductionShelfMaterials" m
    join public."ProductionShelves" sh on sh."Id" = m."ShelfId"
    left join public."Items" i on i."Code" = m."ItemCode"
    left join public."Variants" v on v."VariationId" = m."VariantId"
    order by m."ShelfId", m."SortOrder", m."Id";
end;
$$;

grant execute on function public.staff_get_production_shelf_materials(text, text) to anon;

-- ============================================================================
-- Setting a shelf's list
-- ============================================================================

drop function if exists public.admin_set_production_shelf_materials(text, text, int, jsonb);

-- p_items: [{"item_code": "...", "variant_id": "..." or null, "label": "Black" or null}] - replaces the list.
create or replace function public.admin_set_production_shelf_materials(
  p_admin_username text,
  p_admin_password text,
  p_shelf_id int,
  p_items jsonb
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_item jsonb;
  v_code text;
  v_order int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can change a shelf''s materials.';
  end if;
  if not exists (select 1 from public."ProductionShelves" where "Id" = p_shelf_id) then
    raise exception 'Shelf not found.';
  end if;

  delete from public."ProductionShelfMaterials" where "ShelfId" = p_shelf_id;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_code := nullif(trim(coalesce(v_item->>'item_code', '')), '');
    continue when v_code is null;
    if not exists (select 1 from public."Items" where "Code" = v_code) then
      raise exception 'Item "%" does not exist.', v_code;
    end if;
    insert into public."ProductionShelfMaterials" ("ShelfId", "ItemCode", "VariantId", "Label", "SortOrder")
    values (p_shelf_id, v_code, nullif(trim(coalesce(v_item->>'variant_id', '')), ''),
            nullif(trim(coalesce(v_item->>'label', '')), ''), v_order);
    v_order := v_order + 1;
  end loop;
end;
$$;

grant execute on function public.admin_set_production_shelf_materials(text, text, int, jsonb) to anon;

-- ============================================================================
-- Seed: black / clear sealant on every shelf that has no materials yet
-- ============================================================================
-- Sealant is tracked PER VARIANT (one Sealant item, Black / Clear variants), so the seed adds one row
-- per black / clear VARIANT. An item without variants is only picked when its own name says black /
-- clear. A whole-item sealant row (no variant) on an item that HAS variants - which would add Black
-- and Clear together - is replaced by the per-variant rows (an earlier version of this file seeded
-- those).
do $$
declare
  v_removed int;
  v_found int;
begin
  delete from public."ProductionShelfMaterials" m
  using public."Items" i
  where i."Code" = m."ItemCode"
    and m."VariantId" is null
    and (coalesce(i."Name", '') || ' ' || i."Code") ~* '(sealant|silicone)'
    and exists (select 1 from public."Variants" v where v."ItemCode" = i."Code" or v."MainItemCode" = i."Code");
  get diagnostics v_removed = row_count;

  with sealant_items as (
    select i."Code" as item_code, coalesce(i."Name", '') || ' ' || i."Code" as item_text
    from public."Items" i
    where coalesce(i."IsActive", true)
      and (coalesce(i."Name", '') || ' ' || i."Code") ~* '(sealant|silicone)'
  ),
  candidates as (
    -- per variant
    select s.item_code, v."VariationId" as variant_id,
           coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '') as colour_text
    from sealant_items s
    join public."Variants" v on v."ItemCode" = s.item_code or v."MainItemCode" = s.item_code
    where (coalesce(v."VariantName", '') || ' ' || coalesce(v."SKU", '')) ~* '(black|clear)'
    union all
    -- items with no variants, named black / clear
    select s.item_code, null, s.item_text
    from sealant_items s
    where s.item_text ~* '(black|clear)'
      and not exists (select 1 from public."Variants" v where v."ItemCode" = s.item_code or v."MainItemCode" = s.item_code)
  )
  insert into public."ProductionShelfMaterials" ("ShelfId", "ItemCode", "VariantId", "Label", "SortOrder")
  select sh."Id", c.item_code, c.variant_id,
         case when c.colour_text ~* 'black' then 'Black Sealant' else 'Clear Sealant' end,
         case when c.colour_text ~* 'black' then 0 else 1 end
  from public."ProductionShelves" sh
  -- A variant with its own item row matches twice (via its parent and via itself) - keep one.
  cross join (
    select distinct on (coalesce(cc.variant_id, cc.item_code)) cc.*
    from candidates cc
    order by coalesce(cc.variant_id, cc.item_code), cc.item_code
  ) c
  where not exists (select 1 from public."ProductionShelfMaterials" m where m."ShelfId" = sh."Id");

  get diagnostics v_found = row_count;
  if v_removed > 0 then
    raise notice 'Replaced % whole-item sealant row(s) with per-variant rows.', v_removed;
  end if;
  if v_found = 0 then
    raise notice 'No black/clear sealant variants found by name (or every shelf already has materials) - add them with the Materials button on the Production Shelf Map.';
  else
    raise notice 'Added % sealant row(s) across the shelves - check them on the Production Shelf Map.', v_found;
  end if;
end;
$$;

-- What the seed picked, for a quick check:
-- select sh."Name", m."ItemCode", i."Name", v."VariantName", m."Label"
-- from public."ProductionShelfMaterials" m
-- join public."ProductionShelves" sh on sh."Id" = m."ShelfId"
-- left join public."Items" i on i."Code" = m."ItemCode"
-- left join public."Variants" v on v."VariationId" = m."VariantId"
-- order by sh."Name", m."SortOrder";

notify pgrst, 'reload schema';
