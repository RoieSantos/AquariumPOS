-- Production Shelf Map - minimum stock to maintain, per "as a super user how can I control my
-- production shelf map minimum count" -> "can you share me a view like a list so I can manually
-- change the minimum count to mantain".
--
-- Until now "Low stock" was hard-coded at 1-2 units left for every aquarium. This keeps a minimum
-- per PRODUCT per LOCATION - the same grouping the page's stock list counts by (racks linked to the
-- same aquarium / variant at one location share one count), so the minimum lives in its own table
-- keyed by (WarehouseId, ItemCode, VariantId) rather than on the rack. That also keeps it safe from
-- Edit Layout, which rewrites rack rows. VariantId '' = the "Any variant" rack link.
--
-- The page (docs/js/productionShelfMap.js) shows Low stock when in stock is at or below the minimum,
-- and has a "Minimums" list view where a Super User / Production Manager edits them all at once.
--
--   staff_list_production_shelf_minimums(p_warehouse_id) - any staff who can open the page.
--   admin_save_production_shelf_minimums(p_warehouse_id, p_rows jsonb) - Super User / Production
--     Manager. p_rows = [{"item_code": "...", "variant_id": "" | "...", "min_qty": 5 | null}];
--     null / blank min_qty clears that product's minimum (back to the 1-2 left default).
--
-- Run AFTER supabase_production_orders.sql (_production_is_manager). Safe to re-run.

create table if not exists public."ProductionShelfMinimums" (
    "WarehouseId" varchar(100) not null,
    "ItemCode" varchar(200) not null,
    "VariantId" varchar(100) not null default '',
    "MinQty" int not null check ("MinQty" >= 0),
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now(),
    constraint "PK_ProductionShelfMinimums" primary key ("WarehouseId", "ItemCode", "VariantId")
);

alter table public."ProductionShelfMinimums" enable row level security;
revoke all on public."ProductionShelfMinimums" from anon, authenticated;

-- ---------------------------------------------------------------------------
drop function if exists public.staff_list_production_shelf_minimums(text, text, text);

create or replace function public.staff_list_production_shelf_minimums(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text
)
returns table(item_code text, variant_id text, min_qty int, updated_by text, updated_at_utc timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  return query
    select m."ItemCode"::text, m."VariantId"::text, m."MinQty", m."UpdatedBy"::text, m."UpdatedAtUtc"
    from public."ProductionShelfMinimums" m
    where m."WarehouseId" = p_warehouse_id;
end;
$$;

grant execute on function public.staff_list_production_shelf_minimums(text, text, text) to anon;

-- ---------------------------------------------------------------------------
drop function if exists public.admin_save_production_shelf_minimums(text, text, text, jsonb);

create or replace function public.admin_save_production_shelf_minimums(
  p_admin_username text,
  p_admin_password text,
  p_warehouse_id text,
  p_rows jsonb
)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_row jsonb;
  v_item text;
  v_variant text;
  v_min int;
  v_count int := 0;
begin
  if not public.is_staff_authorized(p_admin_username, p_admin_password)
     or not public._production_is_manager(p_admin_username) then
    raise exception 'Only a Super User or Production Manager can change minimum stock.';
  end if;
  if not exists (select 1 from public."Warehouses" where "ID" = p_warehouse_id) then
    raise exception 'Unknown location.';
  end if;

  for v_row in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    v_item := nullif(trim(coalesce(v_row->>'item_code', '')), '');
    v_variant := trim(coalesce(v_row->>'variant_id', ''));
    if v_item is null then
      continue;
    end if;
    v_min := nullif(trim(coalesce(v_row->>'min_qty', '')), '')::numeric::int;

    if v_min is null then
      delete from public."ProductionShelfMinimums"
      where "WarehouseId" = p_warehouse_id and "ItemCode" = v_item and "VariantId" = v_variant;
    else
      if v_min < 0 then
        raise exception 'Minimum for % can''t be negative.', v_item;
      end if;
      insert into public."ProductionShelfMinimums" ("WarehouseId", "ItemCode", "VariantId", "MinQty", "UpdatedBy", "UpdatedAtUtc")
      values (p_warehouse_id, v_item, v_variant, v_min, p_admin_username, now())
      on conflict ("WarehouseId", "ItemCode", "VariantId") do update
        set "MinQty" = excluded."MinQty", "UpdatedBy" = excluded."UpdatedBy", "UpdatedAtUtc" = now();
    end if;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

grant execute on function public.admin_save_production_shelf_minimums(text, text, text, jsonb) to anon;

notify pgrst, 'reload schema';

-- Verification - one result: the table and both functions.
select 'table' as kind, table_name::text as name
from information_schema.tables
where table_schema = 'public' and table_name = 'ProductionShelfMinimums'
union all
select 'function', p.proname::text
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname in ('staff_list_production_shelf_minimums', 'admin_save_production_shelf_minimums')
order by 1, 2;
